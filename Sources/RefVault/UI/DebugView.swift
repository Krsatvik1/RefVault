import SwiftUI
import AppKit

/// N-way comparison surface. Source = a freshly picked image OR an existing
/// library record. The user can add as many slots as they like; each slot
/// runs the agent against a chosen model, records elapsed time, and is
/// individually committable to the library. Field rows highlight in yellow
/// whenever any slot disagrees with the others.
struct DebugView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var coordinator: IngestionCoordinator

    enum SourceMode: String, CaseIterable, Identifiable {
        case newImage, library
        var id: String { rawValue }
        var label: String { self == .newImage ? "New image" : "From library" }
    }

    /// One column in the comparison table.
    struct RunSlot: Identifiable, Equatable {
        let id = UUID()
        var model: String
        var result: AgentResult? = nil
        var running: Bool = false
        var error: String? = nil
        var elapsed: TimeInterval? = nil
        /// Slot 0 in library mode: the saved record's data. Locked from
        /// re-runs and from being deleted.
        var isLibrarySaved: Bool = false
        /// When true, metadata extraction is split into 5 per-field calls
        /// (style, typography, layout, mood, tags). Tradeoff: ~5× more
        /// Ollama calls for materially better quality on small models.
        var granular: Bool = false
        /// When true, every Ollama call waits for the previous one. Off by
        /// default; default is on at construction (see initializers).
        var serial: Bool = true
        /// Streaming log entries from the agent — populated live during a run.
        var log: [LogLine] = []
        var startedAt: Date? = nil
        /// Pixel ceiling for the image's long edge before sending to Ollama.
        /// 3840 covers 14" Pro Retina screenshots (3024–3456 px) and most
        /// external displays without downscaling. Empirically there's no
        /// material per-call time difference between 1024 and 3840 on 26b,
        /// so we default to "no downscale" for visual fidelity.
        var longEdge: Double = 3840
        /// JPEG quality for the encoded image (0.5 – 1.0). Defaulting to
        /// 1.0 (lossless-ish) for the same reason as longEdge — the wire-
        /// time savings from lower quality are negligible vs the loss of
        /// fine-typography detail Gemma uses for tagging.
        var jpegQuality: Double = 1.0
        /// When true, the model is unloaded from VRAM before each Run. The
        /// next call has to cold-load the weights, so the timing shows the
        /// true first-call cost (~55s for 26b). Useful for comparing
        /// "fresh" runs apples-to-apples.
        var forceCold: Bool = false
    }

    struct LogLine: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let title: String
        let detail: String?
        let kind: Kind
        enum Kind: Equatable { case info, success, warn, error }
    }

    @State private var sourceMode: SourceMode = .newImage
    @State private var pickedURL: URL?
    @State private var pickedRecordID: UUID?

    @State private var slots: [RunSlot] = []

    @State private var availableModels: [String] = OllamaClient.knownGemmaModels
    @State private var savedFlash: String?

    private var pickedRecord: ScreenshotRecord? {
        guard let id = pickedRecordID else { return nil }
        return store.records.first(where: { $0.id == id })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                sourcePanel
                if let flash = savedFlash {
                    Text(flash)
                        .font(.caption)
                        .padding(8)
                        .background(Color.green.opacity(0.15))
                        .cornerRadius(6)
                }
                if !runningSlots.isEmpty {
                    livePanel
                }
                if currentImageURL != nil {
                    Divider()
                    comparisonGrid
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await refreshAvailableModels() }
        .onAppear {
            if slots.isEmpty {
                slots = defaultSlots()
            }
        }
    }

    /// Build the initial pair of slots, inheriting flags from Settings so a
    /// default Debug run matches what auto-ingest would do.
    private func defaultSlots() -> [RunSlot] {
        [
            RunSlot(model: coordinator.primaryModel,
                    granular: coordinator.granularExtraction,
                    serial: coordinator.serialExecution),
            RunSlot(model: coordinator.primaryModel == "gemma4:e4b" ? "gemma4:26b" : "gemma4:e4b",
                    granular: coordinator.granularExtraction,
                    serial: coordinator.serialExecution)
        ]
    }

    private var runningSlots: [RunSlot] {
        slots.filter { $0.running }
    }

    /// Sticky "what's happening right now" panel. Always visible while any
    /// slot is mid-run — saves the user from having to scroll through every
    /// column to follow a single live run.
    private var livePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("LIVE — agent running")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
            }
            ForEach(runningSlots) { slot in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(label(for: slots.firstIndex(where: { $0.id == slot.id }) ?? 0))
                            .font(.caption.weight(.bold))
                        Text(slot.model)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                        if let started = slot.startedAt {
                            Text("· \(String(format: "+%.1fs", Date().timeIntervalSince(started))) elapsed")
                                .font(.caption2.monospaced())
                                .foregroundColor(.secondary)
                        }
                    }
                    if slot.log.isEmpty {
                        Text("waiting for first event…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(slot.log) { line in
                            LogRow(line: line, since: slot.startedAt)
                        }
                    }
                }
                .padding(10)
                .background(Color.secondary.opacity(0.06))
                .cornerRadius(8)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
        )
    }

    // MARK: - Header / source

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Debug · agent comparison")
                .font(.title2.weight(.semibold))
            Text("Run the same image through any number of model configurations, see how long each takes, and commit the version you trust.")
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
                    .onChange(of: pickedRecordID) { _ in seedFromLibrary() }
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

    // MARK: - Comparison grid

    private var comparisonGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(slots.count) run\(slots.count == 1 ? "" : "s")")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    addSlot()
                } label: {
                    Label("Add run", systemImage: "plus")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)

            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(slots.enumerated()), id: \.element.id) { idx, _ in
                        slotColumn(at: idx)
                            .frame(width: 280)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }

    private func slotColumn(at index: Int) -> some View {
        let slot = slots[index]
        let modelBinding = Binding<String>(
            get: { slots[index].model },
            set: { slots[index].model = $0 }
        )
        let canRun = !slot.running && !slot.isLibrarySaved && currentImageURL != nil
        let canSave = canSave(slotIndex: index)

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label(for: index))
                    .font(.headline)
                if slot.isLibrarySaved {
                    Text("saved")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.15))
                        .cornerRadius(4)
                }
                Spacer()
                if let elapsed = slot.elapsed {
                    Text(String(format: "%.1fs", elapsed))
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                }
                if !slot.isLibrarySaved && slots.filter({ !$0.isLibrarySaved }).count > 1 {
                    Button {
                        removeSlot(at: index)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this run")
                }
            }

            if slot.isLibrarySaved {
                Text("from library record")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Picker("Model", selection: modelBinding) {
                    ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                Toggle(isOn: Binding(
                    get: { slots[index].granular },
                    set: { slots[index].granular = $0 }
                )) {
                    Text("Granular (5 calls/field)")
                        .font(.caption)
                }
                .help("Split metadata into 5 per-field calls. Slower but better with small models.")
                Toggle(isOn: Binding(
                    get: { slots[index].serial },
                    set: { slots[index].serial = $0 }
                )) {
                    Text("Serial (one call at a time)")
                        .font(.caption)
                }
                .help("Wait for each Ollama call to finish before starting the next. Recommended.")

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Image long edge")
                            .font(.caption)
                        Spacer()
                        Text("\(Int(slots[index].longEdge))px")
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { slots[index].longEdge },
                            set: { slots[index].longEdge = $0 }
                        ),
                        in: 256...3840,
                        step: 64
                    )
                }
                .help("Cap on the image's largest dimension before encoding. 3840px is effectively no-downscale for any Retina screenshot up to 14\" Pro. Smaller values trade vision fidelity for slightly less wire time — usually not worth it on 26b.")

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("JPEG quality")
                            .font(.caption)
                        Spacer()
                        Text(String(format: "%.2f", slots[index].jpegQuality))
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { slots[index].jpegQuality },
                            set: { slots[index].jpegQuality = $0 }
                        ),
                        in: 0.5...1.0,
                        step: 0.05
                    )
                }
                .help("JPEG quality for the encoded image. Defaults to 1.0 (lossless) — lower values trade typographic detail for marginally smaller payloads.")

                Toggle(isOn: Binding(
                    get: { slots[index].forceCold },
                    set: { slots[index].forceCold = $0 }
                )) {
                    Text("Force cold (unload model first)")
                        .font(.caption)
                }
                .help("Unload the model from VRAM before this run, so the timing reflects a true cold-load (~55s on 26b) rather than reusing a warm model.")

                Button {
                    Task { await runSlot(at: index) }
                } label: {
                    if slot.running {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.small)
                            Text("Running…")
                        }
                    } else {
                        Text(slot.result == nil ? "Run" : "Re-run")
                    }
                }
                .disabled(!canRun)
            }

            if let err = slot.error {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            if let result = slot.result {
                Divider()
                resultBody(forSlotAt: index, result: result)
                Divider()
                Button(saveLabel(for: index)) { commit(slotIndex: index) }
                    .disabled(!canSave)
            } else if !slot.running && slot.log.isEmpty {
                Text("No result yet.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if !slot.log.isEmpty || slot.running {
                Divider()
                logSection(for: slot)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(10)
    }

    @ViewBuilder
    private func logSection(for slot: RunSlot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("LIVE LOG")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(.secondary)
                if slot.running {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            ForEach(slot.log) { line in
                LogRow(line: line, since: slot.startedAt)
            }
        }
    }

    @ViewBuilder
    private func resultBody(forSlotAt index: Int, result: AgentResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            DiffRow(label: "is_design",
                    value: String(result.relevance.isDesign),
                    differs: !allEqual(slots.map { $0.result?.relevance.isDesign }))
            DiffRow(label: "surface",
                    value: result.relevance.surface,
                    differs: !allEqual(slots.map { $0.result?.relevance.surface }))
            DiffRow(label: "device",
                    value: result.relevance.device,
                    differs: !allEqual(slots.map { $0.result?.relevance.device }))
            DiffRow(label: "confidence",
                    value: String(format: "%.2f", result.relevance.confidence),
                    differs: confidencesDiffer())
            DiffRow(label: "browser?",
                    value: String(result.relevance.looksLikeBrowser),
                    differs: !allEqual(slots.map { $0.result?.relevance.looksLikeBrowser }))
            DiffRow(label: "reason",
                    value: result.relevance.reason,
                    differs: !allEqual(slots.map { $0.result?.relevance.reason }),
                    multiline: true)

            if let m = result.metadata {
                Divider()
                DiffRow(label: "style",
                        value: m.style,
                        differs: !allEqual(slots.map { $0.result?.metadata?.style }))
                DiffRow(label: "headings",
                        value: m.typography.headings.joined(separator: ", "),
                        differs: !allEqual(slots.map { $0.result?.metadata?.typography.headings.joined(separator: ", ") }),
                        multiline: true)
                DiffRow(label: "body",
                        value: m.typography.bodies.joined(separator: ", "),
                        differs: !allEqual(slots.map { $0.result?.metadata?.typography.bodies.joined(separator: ", ") }),
                        multiline: true)
                DiffRow(label: "other-type",
                        value: m.typography.others.joined(separator: ", "),
                        differs: !allEqual(slots.map { $0.result?.metadata?.typography.others.joined(separator: ", ") }),
                        multiline: true)
                DiffRow(label: "layout",
                        value: m.layout,
                        differs: !allEqual(slots.map { $0.result?.metadata?.layout }))
                DiffRow(label: "mood",
                        value: m.mood,
                        differs: !allEqual(slots.map { $0.result?.metadata?.mood }))
                DiffRow(label: "tags",
                        value: m.tags.joined(separator: ", "),
                        differs: !allEqual(slots.map { $0.result?.metadata.map { Set($0.tags) } }),
                        multiline: true)
            }

            if let p = result.palette {
                Divider()
                DiffRow(label: "primary",
                        value: p.primary,
                        differs: !allEqual(slots.map { $0.result?.palette?.primary }),
                        swatch: p.primary)
                DiffRow(label: "secondary",
                        value: p.secondary,
                        differs: !allEqual(slots.map { $0.result?.palette?.secondary }),
                        swatch: p.secondary)
                DiffRow(label: "accent",
                        value: p.accent,
                        differs: !allEqual(slots.map { $0.result?.palette?.accent }),
                        swatch: p.accent)
                HStack(spacing: 4) {
                    Text("all")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                        .frame(width: 80, alignment: .leading)
                    ForEach(Array(p.all.enumerated()), id: \.offset) { _, hex in
                        ColorSwatch(hex: hex, size: 14)
                    }
                    Spacer()
                }
            }

            if let v = result.visibleURL {
                Divider()
                DiffRow(label: "url",
                        value: v.url ?? "—",
                        differs: !allEqual(slots.map { $0.result?.visibleURL?.url ?? "" }),
                        multiline: true)
                DiffRow(label: "found_in",
                        value: v.foundIn ?? "—",
                        differs: !allEqual(slots.map { $0.result?.visibleURL?.foundIn ?? "" }))
            }
        }
    }

    // MARK: - Slot actions

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
            clearAllResults()
        }
    }

    private func resetForNewSource() {
        pickedURL = nil
        pickedRecordID = nil
        slots = defaultSlots()
        savedFlash = nil
    }

    private func seedFromLibrary() {
        savedFlash = nil
        guard let rec = pickedRecord else {
            slots = defaultSlots()
            return
        }
        let saved = AgentResult(
            relevance: rec.relevance,
            metadata: rec.metadata,
            palette: rec.palette,
            visibleURL: rec.visibleURL
        )
        slots = [
            RunSlot(
                model: "(saved)",
                result: saved,
                // Surface the original index time on the saved slot so the
                // "20.3s" header sits next to the comparison's live runs.
                // Older records that were indexed before we persisted timing
                // simply leave this nil and the header omits.
                elapsed: rec.processingSeconds,
                isLibrarySaved: true
            ),
            RunSlot(model: "gemma4:e4b")
        ]
    }

    private func clearAllResults() {
        for i in slots.indices {
            if !slots[i].isLibrarySaved {
                slots[i].result = nil
                slots[i].error = nil
                slots[i].elapsed = nil
            }
        }
        savedFlash = nil
    }

    private func addSlot() {
        let nextModel = slots.last(where: { !$0.isLibrarySaved })?.model
            ?? coordinator.primaryModel
        slots.append(RunSlot(
            model: nextModel,
            granular: coordinator.granularExtraction,
            serial: coordinator.serialExecution
        ))
    }

    private func removeSlot(at index: Int) {
        guard slots.indices.contains(index), !slots[index].isLibrarySaved else { return }
        slots.remove(at: index)
    }

    private func runSlot(at index: Int) async {
        guard let url = currentImageURL else { return }
        guard slots.indices.contains(index), !slots[index].isLibrarySaved else { return }
        let slotID = slots[index].id
        slots[index].running = true
        slots[index].error = nil
        slots[index].result = nil
        slots[index].elapsed = nil
        slots[index].log = []
        slots[index].startedAt = Date()
        let model = slots[index].model

        defer {
            if let i = slots.firstIndex(where: { $0.id == slotID }) {
                slots[i].running = false
            }
        }

        let granular = slots[index].granular
        let serial = slots[index].serial
        let longEdge = CGFloat(slots[index].longEdge)
        let jpegQuality = CGFloat(slots[index].jpegQuality)
        let forceCold = slots[index].forceCold
        do {
            if forceCold {
                // Unload first so the upcoming call pays the cold-load
                // cost. We start the elapsed timer AFTER the unload so the
                // reported "20.3s" reflects just the agent.run, not the
                // unload overhead.
                try? await coordinator.agent.client.unload(model: model)
            }
            let runStart = Date()
            let res = try await coordinator.agent.run(
                imageAt: url,
                model: model,
                granular: granular,
                serial: serial,
                longEdge: longEdge,
                jpegQuality: jpegQuality
            ) { event in
                Task { @MainActor in
                    self.appendLog(slotID: slotID, event: event)
                }
            }
            if let i = slots.firstIndex(where: { $0.id == slotID }) {
                slots[i].result = res
                slots[i].elapsed = Date().timeIntervalSince(runStart)
            }
        } catch {
            if let i = slots.firstIndex(where: { $0.id == slotID }) {
                slots[i].error = error.localizedDescription
                slots[i].elapsed = nil
            }
        }
    }

    private func appendLog(slotID: UUID, event: GemmaAgent.Event) {
        guard let i = slots.firstIndex(where: { $0.id == slotID }) else { return }
        let line: LogLine
        switch event {
        case .startedRelevance:
            line = LogLine(timestamp: Date(),
                           title: "Relevance check started",
                           detail: "asking Gemma whether this image is a design reference",
                           kind: .info)
        case .relevanceVerdict(let v):
            let detail = "is_design=\(v.isDesign) · conf=\(String(format: "%.2f", v.confidence)) · \(v.surface)/\(v.device)"
            line = LogLine(timestamp: Date(),
                           title: "Relevance verdict",
                           detail: detail,
                           kind: v.isDesign ? .success : .warn)
        case .startedExtraction:
            line = LogLine(timestamp: Date(),
                           title: "Parallel extraction",
                           detail: "running metadata + palette + url in parallel",
                           kind: .info)
        case .fieldStarted(let name):
            line = LogLine(timestamp: Date(),
                           title: "→ \(name)",
                           detail: "field call dispatched",
                           kind: .info)
        case .field(let name, let snippet):
            line = LogLine(timestamp: Date(),
                           title: "✓ \(name)",
                           detail: snippet,
                           kind: .success)
        case .metadata(let m):
            let detail = "\(m.style) · \(m.layout) · tags: \(m.tags.prefix(5).joined(separator: ", "))"
            line = LogLine(timestamp: Date(),
                           title: "Metadata received",
                           detail: detail,
                           kind: .success)
        case .palette(let p):
            line = LogLine(timestamp: Date(),
                           title: "Palette received",
                           detail: p.all.joined(separator: " · "),
                           kind: .success)
        case .visibleURL(let u):
            line = LogLine(timestamp: Date(),
                           title: "URL extracted",
                           detail: u.url ?? "no url visible",
                           kind: .success)
        case .finished:
            line = LogLine(timestamp: Date(),
                           title: "Run finished",
                           detail: nil,
                           kind: .success)
        case .failed(let error, let stage):
            line = LogLine(timestamp: Date(),
                           title: "Failed at \(stage)",
                           detail: error.localizedDescription,
                           kind: .error)
        }
        slots[i].log.append(line)
    }

    private func canSave(slotIndex: Int) -> Bool {
        guard slots.indices.contains(slotIndex) else { return false }
        let slot = slots[slotIndex]
        if slot.result == nil { return false }
        if slot.isLibrarySaved { return false }
        switch sourceMode {
        case .newImage: return pickedURL != nil
        case .library: return pickedRecord != nil
        }
    }

    private func saveLabel(for slotIndex: Int) -> String {
        let slot = slots[slotIndex]
        if slot.isLibrarySaved { return "Already saved" }
        switch sourceMode {
        case .newImage: return "Save \(label(for: slotIndex)) to library"
        case .library:  return "Replace saved with \(label(for: slotIndex))"
        }
    }

    private func commit(slotIndex: Int) {
        guard slots.indices.contains(slotIndex) else { return }
        let slot = slots[slotIndex]
        guard let res = slot.result else { return }

        switch sourceMode {
        case .library:
            guard let rec = pickedRecord else { return }
            if let updated = store.update(record: rec, with: res, processingSeconds: slot.elapsed) {
                let saved = AgentResult(
                    relevance: updated.relevance,
                    metadata: updated.metadata,
                    palette: updated.palette,
                    visibleURL: updated.visibleURL
                )
                if let savedIdx = slots.firstIndex(where: { $0.isLibrarySaved }) {
                    slots[savedIdx].result = saved
                }
                pickedRecordID = updated.id
                savedFlash = "Replaced library record with \(label(for: slotIndex)) (\(slot.model))."
            }

        case .newImage:
            guard let url = pickedURL else { return }
            if let saved = store.saveRecord(
                from: res,
                sourceURL: url,
                processingSeconds: slot.elapsed
            ) {
                savedFlash = "Saved \(label(for: slotIndex)) (\(slot.model)) as \(saved.id.uuidString.prefix(8))."
            }
        }
    }

    private func label(for index: Int) -> String {
        // Letters: A, B, C, …, Z, AA, AB, …
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        if index < letters.count {
            return String(letters[letters.index(letters.startIndex, offsetBy: index)])
        }
        return "Run \(index + 1)"
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

    // MARK: - Diff helpers

    /// True when two or more populated slots disagree on a value.
    private func allEqual<T: Equatable>(_ values: [T?]) -> Bool {
        let populated = values.compactMap { $0 }
        guard populated.count >= 2 else { return true }
        let first = populated[0]
        return populated.dropFirst().allSatisfy { $0 == first }
    }

    /// Confidence is a Double; treat anything within 0.05 as "the same"
    /// to avoid flagging noise.
    private func confidencesDiffer() -> Bool {
        let values = slots.compactMap { $0.result?.relevance.confidence }
        guard values.count >= 2 else { return false }
        guard let lo = values.min(), let hi = values.max() else { return false }
        return (hi - lo) > 0.05
    }
}

private struct LogRow: View {
    let line: DebugView.LogLine
    let since: Date?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .padding(.top, 5)
            Text(timestampLabel)
                .font(.caption2.monospaced())
                .foregroundColor(.secondary)
                .frame(width: 38, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(line.title)
                    .font(.caption.weight(.medium))
                if let detail = line.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var color: Color {
        switch line.kind {
        case .info:    return .blue
        case .success: return .green
        case .warn:    return .orange
        case .error:   return .red
        }
    }

    private var timestampLabel: String {
        guard let since = since else { return "—" }
        let dt = line.timestamp.timeIntervalSince(since)
        return String(format: "+%.1fs", max(0, dt))
    }
}

private struct DiffRow: View {
    let label: String
    let value: String
    let differs: Bool
    var multiline: Bool = false
    var swatch: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
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
        .padding(.horizontal, 4)
        .padding(.vertical, 3)
        .background(differs ? Color.yellow.opacity(0.20) : Color.clear)
        .cornerRadius(4)
    }
}
