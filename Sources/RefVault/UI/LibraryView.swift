import SwiftUI
import AppKit

struct LibraryView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var coordinator: IngestionCoordinator
    @EnvironmentObject var watcher: ScreenshotWatcher
    @EnvironmentObject var searchModel: SearchModel

    @State private var selectedRecord: ScreenshotRecord?

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)]

    private var query: String { searchModel.query }
    private var parsedFilter: SearchFilter? { searchModel.parsedFilter }
    private var parsedFilterFor: String { searchModel.parsedFilterFor }
    private var isParsing: Bool { searchModel.isParsing }
    private var parseError: String? { searchModel.parseError }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .sheet(item: $selectedRecord) { rec in
            let dims = sheetDimensions(for: rec)
            DetailView(record: rec)
                .frame(width: dims.width, height: dims.height)
        }
    }

    /// Pick a sheet size that lets the image's full aspect ratio fit the
    /// pane with minimal letterboxing. Targets ~92% of the available screen
    /// in whichever direction the image needs most.
    private func sheetDimensions(for rec: ScreenshotRecord) -> (width: CGFloat, height: CGFloat) {
        let metadataColumnWidth: CGFloat = 360
        let chromeVPadding: CGFloat = 24

        let screenSize = NSScreen.main?.visibleFrame.size ??
            CGSize(width: 1440, height: 900)
        let maxW = screenSize.width * 0.92
        let maxH = screenSize.height * 0.92

        let aspect: Double
        if rec.imageWidth > 0, rec.imageHeight > 0 {
            aspect = Double(rec.imageWidth) / Double(rec.imageHeight)
        } else {
            aspect = 16.0 / 10.0
        }

        // Start by maximizing the image's height up to the screen budget,
        // then shrink horizontally if that overflows screen width.
        var imageH = maxH - chromeVPadding
        var imageW = imageH * CGFloat(aspect)
        let availableImageWidth = maxW - metadataColumnWidth
        if imageW > availableImageWidth {
            imageW = availableImageWidth
            imageH = imageW / CGFloat(aspect)
        }
        let totalW = imageW + metadataColumnWidth
        let totalH = imageH + chromeVPadding
        return (
            width:  max(900, totalW),
            height: max(600, totalH)
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Library")
                    .font(.title2.weight(.semibold))
                Text("\(store.records.count)")
                    .font(.title3)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    watcher.scanNow()
                } label: {
                    Label("Scan now", systemImage: "arrow.clockwise")
                }
                Button {
                    watcher.emitExistingFiles()
                } label: {
                    Label("Index existing", systemImage: "tray.and.arrow.down")
                }
                .help("Send every existing screenshot in the watched folders through Gemma. Useful on first launch.")
            }

            // Custom search field — toolbar-embedded TextField with
            // .roundedBorder gave us the system blue focus ring and ugly
            // chrome. Plain text field inside our own capsule lets us
            // own the full look.
            CustomSearchField()

            // Selected chips with × to remove. Sits between the search
            // field and the available-tags row so the selected set
            // visually "lives with" the text input — clicking a chip in
            // the available row promotes it up into this row.
            if !searchModel.selectedTags.isEmpty {
                SelectedTagsRow(
                    selected: searchModel.selectedTags,
                    onRemove: { searchModel.toggleTag($0) }
                )
            }

            // Available tags from library vocabulary, with selected ones
            // filtered out (they live in the selected row above).
            // The color picker sits inline with the tags row so the user
            // can add a color filter alongside tag filters; chosen colors
            // also land in selectedTags and use the same chip UI above.
            HStack(spacing: 8) {
                ColorPickerMenu(
                    selected: searchModel.selectedTags,
                    onPick: { searchModel.toggleTag($0) }
                )
                if !store.vocabulary.tags.isEmpty {
                    let available = store.vocabulary.tags.filter {
                        !searchModel.selectedTags.contains($0)
                    }
                    if !available.isEmpty {
                        TagFilterRow(
                            tags: available,
                            selected: [],
                            onToggle: { searchModel.toggleTag($0) }
                        )
                    }
                }
            }

            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                if let filter = parsedFilter, parsedFilterFor == query, !filter.isEmpty {
                    FilterChips(filter: filter, isParsing: false)
                } else {
                    FilterChips(
                        filter: SearchFilter(freeText: query),
                        isParsing: isParsing
                    )
                }
                if let err = parseError {
                    Text("Couldn't parse query — falling back to keyword match. (\(err))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        let results = currentResults
        if store.records.isEmpty {
            EmptyState(
                title: "No references yet",
                subtitle: watcher.isActive
                    ? "Take a screenshot — it'll show up here once Gemma classifies it as a design reference above the confidence threshold."
                    : "Open Settings to start the watcher, or use Debug to index a single image manually."
            )
        } else if results.isEmpty {
            EmptyState(
                title: "No matches",
                subtitle: "Nothing in the library matches “\(query)”."
            )
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    // In-flight + queued ingest placeholders, rendered
                    // before saved records so the user sees their drop
                    // immediately even though the agent hasn't finished.
                    // We only show the running one when no regen is
                    // active; otherwise the inFlight URL belongs to a
                    // regen and the LibraryCard for that record is
                    // already showing the +Ns pill.
                    if let url = coordinator.inFlight,
                       coordinator.regenerateStartedAt.isEmpty,
                       let started = coordinator.inFlightStartedAt {
                        IngestingCard(url: url, startedAt: started)
                    }
                    ForEach(coordinator.pending, id: \.self) { url in
                        IngestingCard(url: url, startedAt: nil)
                            .contextMenu {
                                Button(role: .destructive) {
                                    coordinator.cancel(url)
                                } label: {
                                    Label("Remove from queue", systemImage: "xmark")
                                }
                            }
                    }
                    ForEach(results) { rec in
                        LibraryCard(record: rec)
                            .onTapGesture { selectedRecord = rec }
                            .contextMenu {
                                Button {
                                    coordinator.regenerate(rec)
                                } label: {
                                    Label("Regenerate", systemImage: "arrow.clockwise")
                                }
                                .disabled(coordinator.regeneratingIds.contains(rec.id))

                                Divider()

                                Button("Open original in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting(
                                        [URL(fileURLWithPath: rec.sourceFilePath)]
                                    )
                                }
                                if let url = store.storedImageURL(for: rec) {
                                    Button("Reveal stored copy in Finder") {
                                        NSWorkspace.shared.activateFileViewerSelecting([url])
                                    }
                                }
                                if let urlStr = rec.visibleURL?.url,
                                   let url = URL(string: urlStr.hasPrefix("http") ? urlStr : "https://\(urlStr)") {
                                    Button("Open URL") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    store.delete(rec)
                                }
                            }
                    }
                }
                .padding(16)
            }
        }
    }
}

extension LibraryView {
    /// Records to render. If Gemma already parsed the current query, use the
    /// structured filter; otherwise fall back to substring search so the grid
    /// reacts immediately to typing while Gemma is in flight.
    fileprivate var currentResults: [ScreenshotRecord] {
        let base: [ScreenshotRecord]
        if let filter = parsedFilter, parsedFilterFor == query, !filter.isEmpty {
            base = store.search(filter: filter)
        } else {
            base = store.search(query)
        }
        let selected = searchModel.selectedTags
        let filtered: [ScreenshotRecord]
        if selected.isEmpty {
            filtered = base
        } else {
            // Selected tokens AND-match either against the record's tags
            // OR against any color family in its palette. This lets a
            // color family ("brown") and a tag ("editorial") coexist as
            // selected chips and the record satisfies both constraints.
            filtered = base.filter { record in
                let recordTags = Set(record.metadata?.tags ?? [])
                let recordColors: Set<String> = Set(
                    (record.palette?.all ?? []).flatMap { ColorNamer.families(for: $0) }
                )
                return selected.allSatisfy { sel in
                    recordTags.contains(sel) || recordColors.contains(sel)
                }
            }
        }
        return searchModel.sorted(filtered)
    }
}

// MARK: Custom search field

private struct CustomSearchField: View {
    @EnvironmentObject var searchModel: SearchModel
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color.secondary.opacity(isFocused ? 0.9 : 0.55))
            TextField("Search references…", text: $searchModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .onChange(of: searchModel.query) { newValue in
                    searchModel.schedule(newValue)
                }
                .onSubmit { searchModel.submit() }
            if searchModel.isParsing {
                ProgressView().controlSize(.small)
            } else if !searchModel.query.isEmpty {
                Button {
                    searchModel.clear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.secondary.opacity(isFocused ? 0.10 : 0.06))
        )
        .overlay(
            // Subtle inner focus ring instead of macOS's harsh blue accent.
            // Tightens up only when focused; otherwise a thin neutral edge.
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(
                    isFocused
                        ? Color.secondary.opacity(0.45)
                        : Color.secondary.opacity(0.20),
                    lineWidth: isFocused ? 1.5 : 1
                )
        )
        .animation(.easeOut(duration: 0.12), value: isFocused)
    }
}

// MARK: Color picker menu

/// Dropdown of broad color families (yellow, green, brown, …). Picking a
/// color toggles it into searchModel.selectedTags using the family name —
/// the result filter then matches the family against any record's
/// palette via ColorNamer.families(for:).
private struct ColorPickerMenu: View {
    let selected: Set<String>
    let onPick: (String) -> Void

    var body: some View {
        Menu {
            ForEach(ColorNamer.allFamilies, id: \.self) { fam in
                Button {
                    onPick(fam)
                } label: {
                    Label {
                        Text(fam.capitalized + (selected.contains(fam) ? "  ✓" : ""))
                    } icon: {
                        Circle().fill(swatch(for: fam))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "paintpalette")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Text("Color")
                    .font(.caption.weight(.medium))
                    .foregroundColor(.primary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.secondary.opacity(0.12)))
            .overlay(Capsule().stroke(Color.secondary.opacity(0.20), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// Approximate swatch color for each family — just for the dropdown
    /// preview, not used for filtering.
    private func swatch(for family: String) -> Color {
        switch family {
        case "black":  return .black
        case "white":  return Color(white: 0.95)
        case "gray":   return Color(white: 0.55)
        case "red":    return Color(red: 0.92, green: 0.20, blue: 0.20)
        case "orange": return Color(red: 1.00, green: 0.55, blue: 0.10)
        case "yellow": return Color(red: 1.00, green: 0.84, blue: 0.10)
        case "green":  return Color(red: 0.30, green: 0.78, blue: 0.35)
        case "teal":   return Color(red: 0.10, green: 0.70, blue: 0.78)
        case "blue":   return Color(red: 0.20, green: 0.45, blue: 0.95)
        case "purple": return Color(red: 0.55, green: 0.32, blue: 0.85)
        case "pink":   return Color(red: 0.95, green: 0.40, blue: 0.65)
        case "brown":  return Color(red: 0.55, green: 0.36, blue: 0.20)
        case "beige":  return Color(red: 0.92, green: 0.86, blue: 0.72)
        default:        return .gray
        }
    }
}

// MARK: Selected tags row (chips with × to remove)

private struct SelectedTagsRow: View {
    let selected: Set<String>
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(selected).sorted(), id: \.self) { tag in
                    Button {
                        onRemove(tag)
                    } label: {
                        HStack(spacing: 5) {
                            Text(tag)
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .fixedSize()
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .opacity(0.85)
                        }
                        .foregroundColor(.white)
                        .padding(.leading, 10)
                        .padding(.trailing, 7)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.accentColor.opacity(0.95)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
    }
}

// MARK: Tag filter row

private struct TagFilterRow: View {
    let tags: [String]
    let selected: Set<String>
    let onToggle: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    let isOn = selected.contains(tag)
                    Button {
                        onToggle(tag)
                    } label: {
                        Text(tag)
                            .font(.caption.weight(isOn ? .semibold : .medium))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(isOn
                                    ? Color.accentColor.opacity(0.95)
                                    : Color.secondary.opacity(0.12))
                            )
                            .foregroundColor(isOn ? .white : .primary)
                            .overlay(
                                Capsule().stroke(
                                    isOn
                                        ? Color.clear
                                        : Color.secondary.opacity(0.20),
                                    lineWidth: 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 1)
        }
    }
}

private struct FilterChips: View {
    let filter: SearchFilter
    let isParsing: Bool

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 80, maximum: 240), spacing: 4)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            if isParsing {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("parsing…")
                        .font(.caption2.monospaced())
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.secondary.opacity(0.15))
                .cornerRadius(4)
            }
            ForEach(chips, id: \.self) { chip in
                Text(chip)
                    .font(.caption2.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundColor(.accentColor)
                    .cornerRadius(4)
            }
        }
    }

    private var chips: [String] {
        var out: [String] = []
        if let v = filter.surfaces, !v.isEmpty { out.append("surface: \(v.joined(separator: "/"))") }
        if let v = filter.devices, !v.isEmpty { out.append("device: \(v.joined(separator: "/"))") }
        if let v = filter.orientations, !v.isEmpty { out.append("orient: \(v.joined(separator: "/"))") }
        if let v = filter.styles, !v.isEmpty { out.append("style: \(v.joined(separator: "/"))") }
        if let v = filter.moods, !v.isEmpty { out.append("mood: \(v.joined(separator: "/"))") }
        if let v = filter.tagsAll, !v.isEmpty { out.append("must: \(v.joined(separator: " + "))") }
        if let v = filter.tagsAny, !v.isEmpty { out.append("any: \(v.joined(separator: " · "))") }
        if let v = filter.colors, !v.isEmpty { out.append("color: \(v.joined(separator: "/"))") }
        if let v = filter.freeText, !v.trimmingCharacters(in: .whitespaces).isEmpty {
            out.append("text: \(v)")
        }
        return out
    }
}

struct LibraryCard: View {
    let record: ScreenshotRecord
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var coordinator: IngestionCoordinator

    private var isRegenerating: Bool {
        coordinator.regeneratingIds.contains(record.id)
    }
    private var rosePrimary: Color {
        Color(red: 1.0, green: 0.216, blue: 0.373)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Image area is locked to a 16:10 aspect (the standard Mac
            // screenshot ratio for both MBP retina and 4K external
            // displays). Long captures (full-page scrolls, sidebar +
            // canvas split, etc.) crop to a screen-shaped preview from
            // the top instead of being squashed into a fixed strip.
            Color.secondary.opacity(0.1)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .overlay {
                    if let url = store.storedImageURL(for: record),
                       let image = NSImage(contentsOf: url) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary)
                    }
                }
                .clipped()

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Badge(label: record.relevance.surface, tone: .blue)
                    Badge(label: record.relevance.device, tone: .purple)
                    Badge(label: record.orientation, tone: .gray)
                    Spacer()
                }

                if let m = record.metadata {
                    Text(m.style.capitalized + " · " + m.layout)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if !m.tags.isEmpty {
                        Text(m.tags.prefix(4).joined(separator: " · "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }
                } else {
                    Text(record.relevance.reason)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }

                if let p = record.palette {
                    HStack(spacing: 4) {
                        ForEach(Array(p.all.prefix(6).enumerated()), id: \.offset) { _, hex in
                            ColorSwatch(hex: hex, size: 12)
                        }
                        Spacer()
                        Text(String(format: "%.0f%%", record.relevance.confidence * 100))
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                    }
                } else {
                    HStack {
                        Spacer()
                        Text(String(format: "%.0f%%", record.relevance.confidence * 100))
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(12)
        }
        // maxWidth pins the OUTER VStack to whatever width the LazyVGrid
        // column hands us. Without this the image area's intrinsic width
        // can leak through the VStack and stretch the card past the
        // grid's column-max constraint, which is what was making the
        // cards look ~500pt wide instead of capping at 320.
        .frame(maxWidth: .infinity)
        .background(Color.secondary.opacity(0.04))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isRegenerating ? rosePrimary : Color.secondary.opacity(0.18),
                    lineWidth: isRegenerating ? 1.5 : 1
                )
        )
        .overlay(alignment: .topTrailing) {
            regenStatusOverlay
                .padding(8)
        }
    }

    /// Three states:
    ///  - In-flight (regenerateStartedAt[id] != nil): live elapsed pill.
    ///  - Queued (in regeneratingIds but no startedAt yet): "queued" pill
    ///    with a × that pulls it out of pendingRegens.
    ///  - Idle: nothing.
    @ViewBuilder
    private var regenStatusOverlay: some View {
        if let started = coordinator.regenerateStartedAt[record.id] {
            // Running now — show a live counter so the user knows it's
            // making progress. TimelineView re-renders this label only,
            // not the rest of the card.
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                let secs = max(0, Int(context.date.timeIntervalSince(started)))
                Text("+\(secs)s")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .tracking(0.5)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(rosePrimary))
            }
        } else if isRegenerating {
            // Queued, not yet picked. Show the label + a × that cancels
            // the queued job (no Ollama call has started, safe to drop).
            HStack(spacing: 4) {
                Text("queued")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(.white)
                Button {
                    coordinator.cancelRegenerate(record)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(rosePrimary))
        }
    }
}

/// Placeholder card for a screenshot that's currently in flight or queued
/// for ingestion. Mirrors LibraryCard's outer dimensions so the grid stays
/// aligned, but the body slot stays empty (no metadata exists yet).
/// Top-right pill mirrors LibraryCard's regen overlay: live elapsed timer
/// when running, "queued ×" when waiting (× is a context-menu action since
/// the queued case is the only cancellable one).
struct IngestingCard: View {
    let url: URL
    /// Wall-clock start of the in-flight run. Nil = still queued.
    let startedAt: Date?
    @EnvironmentObject var coordinator: IngestionCoordinator

    private var rosePrimary: Color {
        Color(red: 1.0, green: 0.216, blue: 0.373)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 16:10 standard Mac screenshot aspect — matches LibraryCard
            // so placeholder slots line up with populated cards in the
            // grid. Long captures crop from the top.
            Color.secondary.opacity(0.1)
                .aspectRatio(16.0 / 10.0, contentMode: .fit)
                .overlay {
                    if let image = NSImage(contentsOf: url) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .opacity(0.55)
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary)
                    }
                }
                .clipped()

            // Body matches LibraryCard's natural footprint without the
            // fixed-height clamp — the LazyVGrid row already equalizes
            // sibling heights, so we don't need to force 140pt here. That
            // was making the placeholder taller than populated cards.
            VStack(alignment: .leading, spacing: 8) {
                Text(url.lastPathComponent)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(startedAt == nil ? "waiting in queue" : "indexing…")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.secondary.opacity(0.04))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(rosePrimary.opacity(startedAt == nil ? 0.4 : 0.9),
                        lineWidth: startedAt == nil ? 1 : 1.5)
        )
        .overlay(alignment: .topTrailing) {
            statusPill
                .padding(8)
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        if let started = startedAt {
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                let secs = max(0, Int(context.date.timeIntervalSince(started)))
                Text("+\(secs)s")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .tracking(0.5)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(rosePrimary))
            }
        } else {
            HStack(spacing: 4) {
                Text("queued")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(.white)
                Button {
                    coordinator.cancel(url)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(.leading, 8)
            .padding(.trailing, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(rosePrimary))
        }
    }
}

struct Badge: View {
    enum Tone { case blue, purple, gray, green, orange }
    let label: String
    let tone: Tone
    var body: some View {
        Text(label)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background)
            .foregroundColor(foreground)
            .cornerRadius(4)
    }
    private var background: Color {
        switch tone {
        case .blue:   return Color.blue.opacity(0.15)
        case .purple: return Color.purple.opacity(0.15)
        case .gray:   return Color.secondary.opacity(0.15)
        case .green:  return Color.green.opacity(0.15)
        case .orange: return Color.orange.opacity(0.15)
        }
    }
    private var foreground: Color {
        switch tone {
        case .blue:   return .blue
        case .purple: return .purple
        case .gray:   return .secondary
        case .green:  return .green
        case .orange: return .orange
        }
    }
}

struct ColorSwatch: View {
    let hex: String
    var size: CGFloat = 14
    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color(hex: hex) ?? Color.secondary.opacity(0.3))
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color.black.opacity(0.1), lineWidth: 0.5)
            )
    }
}

struct EmptyState: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "photo.stack")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text(title).font(.headline)
            Text(subtitle)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        let r = Double((v >> 16) & 0xff) / 255
        let g = Double((v >> 8) & 0xff) / 255
        let b = Double(v & 0xff) / 255
        self = Color(red: r, green: g, blue: b)
    }
}
