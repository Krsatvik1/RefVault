import SwiftUI
import AppKit

/// A/B comparison surface. Source = a freshly picked image OR an existing
/// library record. Each side runs the agent against a chosen model; the
/// columns highlight every field where the two runs disagree. The user picks
/// which run to commit to the library.
struct DebugView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var coordinator: IngestionCoordinator

    enum SourceMode: String, CaseIterable, Identifiable {
        case newImage, library
        var id: String { rawValue }
        var label: String { self == .newImage ? "New image" : "From library" }
    }

    @State private var sourceMode: SourceMode = .newImage
    @State private var pickedURL: URL?
    @State private var pickedRecordID: UUID?

    private var pickedRecord: ScreenshotRecord? {
        guard let id = pickedRecordID else { return nil }
        return store.records.first(where: { $0.id == id })
    }

    @State private var modelA: String = OllamaClient.defaultModel
    @State private var modelB: String = "gemma4:26b"

    @State private var resultA: AgentResult?
    @State private var resultB: AgentResult?
    @State private var runningA = false
    @State private var runningB = false
    @State private var errorA: String?
    @State private var errorB: String?

    @State private var availableModels: [String] = OllamaClient.knownGemmaModels
    @State private var savedFlash: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                sourcePanel
                if currentImageURL != nil {
                    Divider()
                    HStack(alignment: .top, spacing: 12) {
                        column(side: .a)
                        Divider()
                        column(side: .b)
                    }
                }
                if let flash = savedFlash {
                    Text(flash)
                        .font(.caption)
                        .padding(8)
                        .background(Color.green.opacity(0.15))
                        .cornerRadius(6)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await refreshAvailableModels() }
    }

    // MARK: - Header / source

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Debug · A/B comparison")
                .font(.title2.weight(.semibold))
            Text("Run the same image through two model configurations, compare every field, then commit the version you trust.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var sourcePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Source", selection: $sourceMode) {
                ForEach(SourceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: sourceMode) { _ in resetForNewSource() }
            .frame(maxWidth: 320)

            switch sourceMode {
            case .newImage:
                HStack {
                    Button("Pick image…") { pickImage() }
                    if let url = pickedURL {
                        Text(url.lastPathComponent)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            case .library:
                if store.records.isEmpty {
                    Text("Library is empty — index something first.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Picker("Record", selection: $pickedRecordID) {
                        Text("— choose a record —").tag(UUID?.none)
                        ForEach(store.records) { rec in
                            Text(recordPickerLabel(rec))
                                .tag(Optional(rec.id))
                        }
                    }
                    .frame(maxWidth: 480)
                    .onChange(of: pickedRecordID) { _ in
                        guard let rec = pickedRecord else {
                            resultA = nil
                            return
                        }
                        // Side A pre-filled from saved record; side B blank, ready for regen.
                        resultA = AgentResult(
                            relevance: rec.relevance,
                            metadata: rec.metadata,
                            palette: rec.palette,
                            visibleURL: rec.visibleURL
                        )
                        resultB = nil
                        errorA = nil
                        errorB = nil
                        savedFlash = nil
                    }
                }
            }

            if let url = currentImageURL, let img = NSImage(contentsOf: url) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 200)
                    .background(Color.secondary.opacity(0.08))
                    .cornerRadius(6)
            }
        }
    }

    // MARK: - Side columns

    private enum Side { case a, b }

    @ViewBuilder
    private func column(side: Side) -> some View {
        let title = side == .a ? "A" : "B"
        let model = Binding<String>(
            get: { side == .a ? modelA : modelB },
            set: { if side == .a { modelA = $0 } else { modelB = $0 } }
        )
        let result = side == .a ? resultA : resultB
        let other  = side == .a ? resultB : resultA
        let running = side == .a ? runningA : runningB
        let error = side == .a ? errorA : errorB
        let isAFromLibrary = (side == .a && sourceMode == .library)

        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.title3.weight(.semibold))
                if isAFromLibrary {
                    Text("Saved in library")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(4)
                }
                Spacer()
            }

            HStack {
                Picker("Model", selection: model) {
                    ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .disabled(isAFromLibrary)
                Button(running ? "Running…" : "Run") {
                    Task { await run(side: side) }
                }
                .disabled(running || currentImageURL == nil || isAFromLibrary)
            }

            if let error = error {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if let result = result {
                resultBody(result: result, other: other)
                Divider()
                Button(saveLabel(for: side)) { commit(side: side) }
                    .disabled(!canSave(side: side))
                    .keyboardShortcut(side == .b ? .defaultAction : .init(.return, modifiers: .shift))
            } else if running {
                ProgressView().controlSize(.small)
            } else {
                Text(isAFromLibrary
                    ? "Pick a library record above to populate this side."
                    : "Run the agent to see results here.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func resultBody(result: AgentResult, other: AgentResult?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            DiffRow(label: "is_design",
                    value: String(result.relevance.isDesign),
                    differs: other.map { $0.relevance.isDesign != result.relevance.isDesign } ?? false)
            DiffRow(label: "surface",
                    value: result.relevance.surface,
                    differs: other.map { $0.relevance.surface != result.relevance.surface } ?? false)
            DiffRow(label: "device",
                    value: result.relevance.device,
                    differs: other.map { $0.relevance.device != result.relevance.device } ?? false)
            DiffRow(label: "confidence",
                    value: String(format: "%.2f", result.relevance.confidence),
                    differs: other.map { abs($0.relevance.confidence - result.relevance.confidence) > 0.05 } ?? false)
            DiffRow(label: "browser?",
                    value: String(result.relevance.looksLikeBrowser),
                    differs: other.map { $0.relevance.looksLikeBrowser != result.relevance.looksLikeBrowser } ?? false)
            DiffRow(label: "reason",
                    value: result.relevance.reason,
                    differs: other.map { $0.relevance.reason != result.relevance.reason } ?? false,
                    multiline: true)

            if let m = result.metadata {
                Divider()
                DiffRow(label: "style",
                        value: m.style,
                        differs: other?.metadata.map { $0.style != m.style } ?? false)
                DiffRow(label: "typography",
                        value: m.typography,
                        differs: other?.metadata.map { $0.typography != m.typography } ?? false)
                DiffRow(label: "layout",
                        value: m.layout,
                        differs: other?.metadata.map { $0.layout != m.layout } ?? false)
                DiffRow(label: "mood",
                        value: m.mood,
                        differs: other?.metadata.map { $0.mood != m.mood } ?? false)
                DiffRow(label: "tags",
                        value: m.tags.joined(separator: ", "),
                        differs: other?.metadata.map { Set($0.tags) != Set(m.tags) } ?? false,
                        multiline: true)
            }

            if let p = result.palette {
                Divider()
                DiffRow(label: "primary",
                        value: p.primary,
                        differs: other?.palette.map { $0.primary != p.primary } ?? false,
                        swatch: p.primary)
                DiffRow(label: "secondary",
                        value: p.secondary,
                        differs: other?.palette.map { $0.secondary != p.secondary } ?? false,
                        swatch: p.secondary)
                DiffRow(label: "accent",
                        value: p.accent,
                        differs: other?.palette.map { $0.accent != p.accent } ?? false,
                        swatch: p.accent)
                HStack(spacing: 4) {
                    Text("all")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                        .frame(width: 90, alignment: .leading)
                    ForEach(Array(p.all.enumerated()), id: \.offset) { _, hex in
                        ColorSwatch(hex: hex, size: 16)
                    }
                    Spacer()
                }
            }

            if let v = result.visibleURL {
                Divider()
                DiffRow(label: "url",
                        value: v.url ?? "—",
                        differs: other?.visibleURL.map { ($0.url ?? "") != (v.url ?? "") } ?? false,
                        multiline: true)
                DiffRow(label: "found_in",
                        value: v.foundIn ?? "—",
                        differs: other?.visibleURL.map { ($0.foundIn ?? "") != (v.foundIn ?? "") } ?? false)
            }
        }
    }

    // MARK: - Actions

    private var currentImageURL: URL? {
        switch sourceMode {
        case .newImage: return pickedURL
        case .library:
            guard let rec = pickedRecord else { return nil }
            return store.storedImageURL(for: rec)
        }
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            pickedURL = url
            resetResults()
        }
    }

    private func resetForNewSource() {
        pickedURL = nil
        pickedRecordID = nil
        resetResults()
    }

    private func resetResults() {
        resultA = nil
        resultB = nil
        errorA = nil
        errorB = nil
        savedFlash = nil
    }

    private func run(side: Side) async {
        guard let url = currentImageURL else { return }
        let model = side == .a ? modelA : modelB
        if side == .a { runningA = true; errorA = nil }
        else          { runningB = true; errorB = nil }
        defer {
            if side == .a { runningA = false } else { runningB = false }
        }
        do {
            let res = try await coordinator.agent.run(imageAt: url, model: model)
            if side == .a { resultA = res } else { resultB = res }
        } catch {
            if side == .a { errorA = error.localizedDescription }
            else          { errorB = error.localizedDescription }
        }
    }

    private func canSave(side: Side) -> Bool {
        switch (sourceMode, side) {
        case (.library, .a):
            return false  // already in library
        case (.library, .b):
            return resultB != nil && pickedRecord != nil
        case (.newImage, _):
            return (side == .a ? resultA : resultB) != nil
        }
    }

    private func saveLabel(for side: Side) -> String {
        switch (sourceMode, side) {
        case (.library, .a): return "Already saved"
        case (.library, .b): return "Replace saved with B"
        case (.newImage, .a): return "Save A to library"
        case (.newImage, .b): return "Save B to library"
        }
    }

    private func commit(side: Side) {
        switch (sourceMode, side) {
        case (.library, .b):
            guard let rec = pickedRecord, let res = resultB else { return }
            if let updated = store.update(record: rec, with: res) {
                pickedRecordID = updated.id
                resultA = AgentResult(
                    relevance: updated.relevance,
                    metadata: updated.metadata,
                    palette: updated.palette,
                    visibleURL: updated.visibleURL
                )
                resultB = nil
                savedFlash = "Replaced library record with B (\(modelB))."
            }
        case (.newImage, .a):
            guard let url = pickedURL, let res = resultA else { return }
            if let saved = store.saveRecord(from: res, sourceURL: url) {
                savedFlash = "Saved A as \(saved.id.uuidString.prefix(8))."
            }
        case (.newImage, .b):
            guard let url = pickedURL, let res = resultB else { return }
            if let saved = store.saveRecord(from: res, sourceURL: url) {
                savedFlash = "Saved B as \(saved.id.uuidString.prefix(8))."
            }
        default:
            break
        }
    }

    private func recordPickerLabel(_ rec: ScreenshotRecord) -> String {
        let surface = rec.relevance.surface
        let style = rec.metadata?.style ?? "—"
        let name = URL(fileURLWithPath: rec.sourceFilePath).lastPathComponent
        return "\(name) · \(surface) · \(style)"
    }

    private func refreshAvailableModels() async {
        do {
            let installed = try await coordinator.agent.client.listModels()
            let gemmas = installed.filter { $0.hasPrefix("gemma4") }
            let merged = Array(Set(gemmas + OllamaClient.knownGemmaModels)).sorted()
            await MainActor.run { availableModels = merged }
        } catch {
            // keep the static list
        }
    }
}

private struct DiffRow: View {
    let label: String
    let value: String
    let differs: Bool
    var multiline: Bool = false
    var swatch: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)
                .frame(width: 90, alignment: .leading)
            if let hex = swatch {
                ColorSwatch(hex: hex, size: 14)
            }
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(multiline ? 4 : 1)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(differs ? Color.yellow.opacity(0.18) : Color.clear)
        .cornerRadius(4)
    }
}
