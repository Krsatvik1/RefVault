import SwiftUI
import AppKit

/// Bare-minimum UI: pick an image, run the Gemma agent, watch the pipeline
/// emit events into a streaming log. No DB, no watcher, no search yet —
/// this is the proof that the agentic flow works end-to-end.
struct MainWindow: View {
    @StateObject private var vm = AgentRunVM()

    var body: some View {
        HStack(spacing: 0) {
            // Left: image preview + controls
            VStack(alignment: .leading, spacing: 12) {
                Group {
                    if let preview = vm.previewImage {
                        Image(nsImage: preview)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.secondary.opacity(0.08))
                            .cornerRadius(6)
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.secondary.opacity(0.08))
                            Text("No image selected")
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }

                HStack {
                    Button("Pick image…") { vm.pickImage() }
                    Button(vm.isRunning ? "Indexing…" : "Index with Gemma") {
                        Task { await vm.runAgent() }
                    }
                    .disabled(vm.imageURL == nil || vm.isRunning)
                    .keyboardShortcut(.defaultAction)
                    Spacer()
                    Text(vm.modelStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let url = vm.imageURL {
                    Text(url.lastPathComponent)
                        .font(.caption.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(16)
            .frame(width: 360)

            Divider()

            // Right: streaming agent log
            VStack(alignment: .leading, spacing: 8) {
                Text("Agent log")
                    .font(.headline)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(vm.log) { entry in
                            LogRow(entry: entry)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(6)

                if let recordJSON = vm.finalJSON {
                    Text("Final record")
                        .font(.headline)
                    ScrollView {
                        Text(recordJSON)
                            .font(.body.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .frame(maxHeight: 180)
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(6)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .task { await vm.checkOllama() }
    }
}

private struct LogRow: View {
    let entry: AgentRunVM.LogEntry
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(entry.color)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).font(.callout.weight(.semibold))
                if let detail = entry.detail {
                    Text(detail)
                        .font(.callout.monospaced())
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
    }
}

// MARK: - View model

@MainActor
final class AgentRunVM: ObservableObject {
    @Published var imageURL: URL?
    @Published var previewImage: NSImage?
    @Published var isRunning = false
    @Published var log: [LogEntry] = []
    @Published var finalJSON: String?
    @Published var modelStatus: String = "Checking Ollama…"

    private let client: OllamaClient
    private let agent: GemmaAgent

    init() {
        let client = OllamaClient()
        self.client = client
        self.agent = GemmaAgent(client: client)
    }

    func checkOllama() async {
        do {
            let models = try await client.listModels()
            if models.contains(where: { $0.hasPrefix("gemma4") }) {
                modelStatus = "Ollama OK · gemma4 available"
            } else if models.isEmpty {
                modelStatus = "Ollama OK · no models pulled"
            } else {
                modelStatus = "Ollama OK · gemma4 not pulled"
            }
        } catch {
            modelStatus = "Ollama unreachable"
        }
    }

    func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            imageURL = url
            previewImage = NSImage(contentsOf: url)
            log.removeAll()
            finalJSON = nil
        }
    }

    func runAgent() async {
        guard let url = imageURL, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        log.removeAll()
        finalJSON = nil

        let stream = AsyncStream<GemmaAgent.Event> { cont in
            Task {
                do {
                    _ = try await agent.index(imageAt: url) { event in
                        cont.yield(event)
                    }
                    cont.finish()
                } catch {
                    cont.yield(.failed(error, stage: "agent"))
                    cont.finish()
                }
            }
        }

        for await event in stream {
            append(event)
        }
    }

    private func append(_ event: GemmaAgent.Event) {
        switch event {
        case .startedRelevance:
            log.append(.init(title: "Relevance check started", detail: nil, color: .gray))
        case .relevanceVerdict(let v):
            let detail = "is_design=\(v.isDesign) confidence=\(String(format: "%.2f", v.confidence)) — \(v.reason)"
            log.append(.init(
                title: "Relevance verdict",
                detail: detail,
                color: v.isDesign ? .green : .orange
            ))
        case .startedExtraction:
            log.append(.init(title: "Parallel extraction…", detail: nil, color: .blue))
        case .metadata(let m):
            log.append(.init(
                title: "Design metadata",
                detail: "style=\(m.style) · type=\(m.typography) · layout=\(m.layout) · mood=\(m.mood)\ntags: \(m.tags.joined(separator: ", "))",
                color: .purple
            ))
        case .palette(let p):
            log.append(.init(
                title: "Color palette",
                detail: "primary=\(p.primary) secondary=\(p.secondary) accent=\(p.accent)\nall: \(p.all.joined(separator: ", "))",
                color: .pink
            ))
        case .visibleURL(let u):
            log.append(.init(
                title: "Visible URL",
                detail: u.url.map { "\($0)  (in: \(u.foundIn ?? "?"))" } ?? "none found",
                color: .teal
            ))
        case .finished(let record):
            finalJSON = encodePretty(record)
            log.append(.init(title: "Done", detail: nil, color: .green))
        case .failed(let error, let stage):
            log.append(.init(
                title: "Failed at \(stage)",
                detail: error.localizedDescription,
                color: .red
            ))
        }
    }

    private func encodePretty<T: Encodable>(_ value: T) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return (try? String(data: enc.encode(value), encoding: .utf8)) ?? ""
    }

    struct LogEntry: Identifiable {
        let id = UUID()
        let title: String
        let detail: String?
        let color: Color
    }
}
