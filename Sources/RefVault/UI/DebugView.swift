import SwiftUI
import AppKit

/// The original "pick an image, watch the agent run" workflow, now repurposed
/// as a debug surface alongside the live library.
struct DebugView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var coordinator: IngestionCoordinator

    @State private var imageURL: URL?
    @State private var previewImage: NSImage?
    @State private var isRunning = false
    @State private var log: [LogEntry] = []
    @State private var lastResult: AgentResult?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Group {
                    if let preview = previewImage {
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
                    Button("Pick image…") { pickImage() }
                    Button(isRunning ? "Indexing…" : "Run agent") {
                        Task { await runAgent() }
                    }
                    .disabled(imageURL == nil || isRunning)
                    .keyboardShortcut(.defaultAction)
                }

                HStack {
                    Button("Save to library") {
                        if let url = imageURL, let res = lastResult {
                            _ = store.saveRecord(from: res, sourceURL: url)
                        }
                    }
                    .disabled(lastResult == nil || imageURL == nil)
                    .help("Forces a save regardless of confidence threshold.")
                    Spacer()
                }

                if let url = imageURL {
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

            VStack(alignment: .leading, spacing: 8) {
                Text("Agent log")
                    .font(.headline)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(log) { entry in
                            LogRow(entry: entry)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(6)

                if let res = lastResult {
                    Text("Result")
                        .font(.headline)
                    ScrollView {
                        Text(prettyJSON(res))
                            .font(.body.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .frame(maxHeight: 200)
                    .background(Color.secondary.opacity(0.05))
                    .cornerRadius(6)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Actions

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            imageURL = url
            previewImage = NSImage(contentsOf: url)
            log.removeAll()
            lastResult = nil
        }
    }

    private func runAgent() async {
        guard let url = imageURL, !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        log.removeAll()
        lastResult = nil

        let stream = AsyncStream<GemmaAgent.Event> { cont in
            Task {
                do {
                    _ = try await coordinator.agent.run(imageAt: url) { event in
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
            await MainActor.run { append(event) }
        }
    }

    private func append(_ event: GemmaAgent.Event) {
        switch event {
        case .startedRelevance:
            log.append(.init(title: "Relevance check started", detail: nil, color: .gray))
        case .relevanceVerdict(let v):
            let detail = "is_design=\(v.isDesign) conf=\(String(format: "%.2f", v.confidence)) · \(v.surface)/\(v.device)\n\(v.reason)"
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
        case .finished(let result):
            lastResult = result
            log.append(.init(title: "Done", detail: nil, color: .green))
        case .failed(let error, let stage):
            log.append(.init(
                title: "Failed at \(stage)",
                detail: error.localizedDescription,
                color: .red
            ))
        }
    }

    private func prettyJSON(_ result: AgentResult) -> String {
        struct Wrapper: Encodable {
            let relevance: RelevanceVerdict
            let metadata: DesignMetadata?
            let palette: ColorPalette?
            let visibleURL: VisibleURL?
        }
        let wrapper = Wrapper(
            relevance: result.relevance,
            metadata: result.metadata,
            palette: result.palette,
            visibleURL: result.visibleURL
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? String(data: enc.encode(wrapper), encoding: .utf8)) ?? ""
    }
}

private struct LogEntry: Identifiable {
    let id = UUID()
    let title: String
    let detail: String?
    let color: Color
}

private struct LogRow: View {
    let entry: LogEntry
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
