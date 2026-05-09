import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Private UTI tagged onto every `.onDrag` initiated from inside RefVault
/// (LibraryCard + popover resultCard). The drop target on LibraryView
/// rejects any drop whose providers carry this type, so picking up a card
/// and pausing the cursor over the library doesn't flash the import
/// overlay. `.ownProcess` visibility means other apps never see this UTI
/// — Finder/Slack/Figma still get the regular `.fileURL` representation.
extension UTType {
    static let refVaultInternalCardDrag = UTType(
        exportedAs: "com.refvault.internalCardDrag"
    )
}

struct LibraryView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var coordinator: IngestionCoordinator
    @EnvironmentObject var watcher: ScreenshotWatcher
    @EnvironmentObject var searchModel: SearchModel

    @State private var selectedRecord: ScreenshotRecord?
    @State private var isImportTargeted = false

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
        .onDrop(
            of: [.fileURL],
            delegate: LibraryImportDropDelegate(
                isTargeted: $isImportTargeted,
                coordinator: coordinator
            )
        )
        .overlay {
            if isImportTargeted {
                ImportDropOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.12), value: isImportTargeted)
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

            // Unified chip vocabulary — every searchable attribute across
            // the library (style, mood, layout, tags, typography, surface,
            // device, orientation) ranked by frequency. Picking any chip
            // narrows the grid via chipHaystack which matches the same
            // attributes. Selected chips are filtered out (they live in
            // the selected row above). Color stays in its own dropdown
            // since color families are derived from palettes, not metadata.
            HStack(spacing: 8) {
                ColorPickerMenu(
                    selected: searchModel.selectedTags,
                    onPick: { searchModel.toggleTag($0) }
                )
                TypographyPickerMenu(
                    vocab: store.typographyVocabulary,
                    selected: searchModel.selectedTags,
                    onPick: { searchModel.toggleTag($0) }
                )
                let available = store.chipVocabulary.filter {
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

            // No parsed-filter chip row. After Gemma parses, every
            // categorical value (mood/style/tags/colors/etc) is promoted
            // into searchModel.selectedTags, so the user sees a single
            // unified row of blue chips above instead of two parallel
            // chip styles for the same thing.
            if let err = parseError, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Couldn't parse query — falling back to keyword match. (\(err))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        let results = currentResults
        if searchModel.isParsing {
            // Live searching state — big spinner + the query Gemma is
            // currently working on. Replaces the "No matches" empty state
            // that was flashing while the parse was still in flight.
            SearchingState(query: query, startedAt: searchModel.parseStartedAt)
        } else if store.records.isEmpty {
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

/// All tokens a single record can match against — every selected chip
/// must hit one of these. Lowercased so chip-side normalization in
/// SearchModel.launchParse matches without case wobble. Module-internal
/// so MenuBarContent's popover filter can use the same haystack.
func chipHaystack(for record: ScreenshotRecord) -> Set<String> {
    var set = Set<String>()
    if let m = record.metadata {
        set.formUnion(m.tags.map { $0.lowercased() })
        set.insert(m.style.lowercased())
        set.insert(m.mood.lowercased())
        set.insert(m.layout.lowercased())
        // Slot-qualified typography tokens. Each font name expands to
        // its specific token AND its class fallback ("mono", "serif",
        // "sans-serif"), because Gemma usually stores the family name
        // (e.g. "JetBrains Mono"), not the abstract class — without the
        // fallback the chip "heading: mono" wouldn't match a record
        // whose haystack only has "heading: jetbrains mono".
        for f in m.typography.headings {
            set.formUnion(typographyTokens(slot: "heading", font: f))
        }
        for f in m.typography.bodies {
            set.formUnion(typographyTokens(slot: "body", font: f))
        }
        for f in m.typography.others {
            set.formUnion(typographyTokens(slot: "other", font: f))
        }
    }
    if let palette = record.palette {
        let families = palette.all.flatMap { ColorNamer.families(for: $0) }
        set.formUnion(families.map { $0.lowercased() })
    }
    set.insert(record.relevance.surface.lowercased())
    set.insert(record.relevance.device.lowercased())
    set.insert(record.orientation.lowercased())
    return set
}

/// Slot-qualified tokens for a single font name. Always emits the
/// specific token (e.g. "heading: jetbrains mono") and any class
/// fallbacks the font name implies — so picking "mono" / "serif" /
/// "sans-serif" from the dropdown catches every member of that family
/// even when the record stored a specific name.
///
/// "sans" check runs before "serif" because every "sans-serif" string
/// contains "serif" too — without the order guard a sans-serif font
/// would also fire the serif fallback, which is wrong.
private func typographyTokens(slot: String, font: String) -> Set<String> {
    let lower = font.lowercased()
    var out: Set<String> = ["\(slot): \(lower)"]
    if lower.contains("mono") {
        out.insert("\(slot): mono")
    }
    if lower.contains("sans") {
        out.insert("\(slot): sans-serif")
    } else if lower.contains("serif") {
        out.insert("\(slot): serif")
    }
    return out
}

extension LibraryView {
    /// Records to render. Driven by `searchModel.committedQuery`, NOT the
    /// live-typing `query` — that means the grid only re-filters after the
    /// debounce window expires (or the user hits Enter). Without this the
    /// substring fallback fired on every keystroke and the grid felt jumpy.
    /// Gemma-parsed values are no longer used as a separate filter path —
    /// they're promoted into selectedTags after each parse, so the chip
    /// AND-match below picks them up uniformly with manual chips.
    ///
    /// Substring source: when Gemma's parse succeeded, use `freeText` (the
    /// part of the query Gemma couldn't slot into a structured field) —
    /// NOT the raw committedQuery. Otherwise a query like "i want
    /// something clean" gets the "clean" chip promoted AND tries to
    /// substring-match the literal phrase "i want something clean" in
    /// every record's haystack, which finds nothing — the intersection
    /// of the chip filter and a guaranteed-empty substring is zero.
    fileprivate var currentResults: [ScreenshotRecord] {
        let substring: String = {
            if let f = searchModel.parsedFilter, !f.isEmpty {
                return f.freeText?.trimmingCharacters(in: .whitespaces) ?? ""
            }
            return searchModel.committedQuery
        }()
        let base: [ScreenshotRecord]
        if !substring.isEmpty {
            base = store.search(substring)
        } else {
            base = store.records
        }
        let selected = searchModel.selectedTags
        let filtered: [ScreenshotRecord]
        if selected.isEmpty {
            filtered = base
        } else {
            // Each selected chip AND-matches anywhere in the record's
            // metadata: tags, palette color families, style, mood, layout,
            // surface, device. This lets Gemma-promoted chips ("edgy" for
            // mood, "minimal" for style) coexist with manual tag chips
            // and color chips in one unified row, and a record satisfies
            // a chip if it matches on any field.
            filtered = base.filter { record in
                let haystack = chipHaystack(for: record)
                return selected.allSatisfy { haystack.contains($0.lowercased()) }
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
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    if let started = searchModel.parseStartedAt {
                        // Live "+Ns" so the user knows the parse is still
                        // running (and how long it's been). TimelineView
                        // ticks the label only — doesn't re-render the
                        // text field or its binding.
                        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                            let secs = max(0, Int(ctx.date.timeIntervalSince(started)))
                            Text("+\(secs)s")
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }
                }
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
            // Submit button — same effect as pressing Return. Visible
            // whenever there's a non-empty query, regardless of parsing
            // state, so the user can re-fire the parse if a previous one
            // failed.
            if !searchModel.query.isEmpty {
                Button {
                    searchModel.submit()
                } label: {
                    Image(systemName: "return")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.secondary.opacity(0.12))
                        )
                }
                .buttonStyle(.plain)
                .help("Run search")
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

// MARK: Typography picker

/// Dropdown that mirrors ColorPickerMenu but shows the library's actual
/// font tokens grouped by their slot in each record (Headings / Bodies /
/// Others). Picking a font adds it to selectedTags; chipHaystack already
/// matches typography fields so the grid filters automatically.
private struct TypographyPickerMenu: View {
    let vocab: LibraryStore.TypographyVocabulary
    let selected: Set<String>
    let onPick: (String) -> Void

    private static let genericClasses = ["serif", "sans-serif", "mono"]

    var body: some View {
        Menu {
            // Each section is slot-qualified — picking "serif" under
            // Headings adds "heading: serif" to selectedTags, which
            // matches only records whose typography.headings field
            // contains "serif". Generic classes (serif/sans-serif/mono)
            // are always offered alongside the library's actual fonts.
            Section("Headings") {
                ForEach(menuItems(for: vocab.headings), id: \.self) { f in
                    pickerButton(slot: "heading", value: f)
                }
            }
            Section("Bodies") {
                ForEach(menuItems(for: vocab.bodies), id: \.self) { f in
                    pickerButton(slot: "body", value: f)
                }
            }
            Section("Others") {
                ForEach(menuItems(for: vocab.others), id: \.self) { f in
                    pickerButton(slot: "other", value: f)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "textformat")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.secondary)
                Text("Typography")
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

    /// Generic classes always at the top, then library-specific fonts
    /// (deduped against the generics so "sans-serif" doesn't appear twice
    /// when Gemma already extracted it as a heading).
    private func menuItems(for libFonts: [String]) -> [String] {
        let lowerLib = Set(libFonts.map { $0.lowercased() })
        let extras = libFonts.filter { !Self.genericClasses.contains($0.lowercased()) }
        var out = Self.genericClasses
        out.append(contentsOf: extras)
        // (lowerLib used to silence warnings if extras is empty)
        _ = lowerLib
        return out
    }

    @ViewBuilder
    private func pickerButton(slot: String, value: String) -> some View {
        let token = "\(slot): \(value.lowercased())"
        let isSel = selected.contains(token)
        Button {
            onPick(token)
        } label: {
            Text(value + (isSel ? "  ✓" : ""))
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

    /// Cached loaded image. Without this, every body re-evaluation
    /// (including the one that fires on every keystroke in the search
    /// field, because the entire view tree observes searchModel) re-reads
    /// the screenshot from disk via NSImage(contentsOf:). With ~14 visible
    /// cards × multi-MB PNGs that turns into hundreds of milliseconds of
    /// disk I/O per keystroke and the field feels sluggish.
    @State private var cachedImage: NSImage?

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
                    if let image = cachedImage {
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
                .task(id: record.id) {
                    // Off-main disk read so it doesn't block the typing
                    // path. Only fires once per card lifecycle (re-runs
                    // only when record.id changes). Loads Data off-main
                    // then constructs NSImage on the main actor — NSImage
                    // isn't Sendable on macOS 13, Data is.
                    guard cachedImage == nil,
                          let url = store.storedImageURL(for: record) else { return }
                    let data = await Task.detached(priority: .userInitiated) {
                        try? Data(contentsOf: url)
                    }.value
                    if !Task.isCancelled, let data {
                        cachedImage = NSImage(data: data)
                    }
                }

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
        // Drag the card to drop the underlying screenshot file into any
        // app (Figma, Slack, Mail, Finder, browser tab). NSItemProvider
        // registered with the file URL gives receivers the real file —
        // they decide whether to copy, upload, or embed.
        .onDrag {
            if let url = store.storedImageURL(for: record),
               let provider = NSItemProvider(contentsOf: url) {
                provider.suggestedName = url.lastPathComponent
                tagAsInternalDrag(provider)
                return provider
            }
            return NSItemProvider()
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

/// Shown while Gemma is parsing the query. Replaces the "No matches"
/// empty state that was flashing during the wait — that copy was
/// misleading because we hadn't actually finished searching yet.
struct SearchingState: View {
    let query: String
    let startedAt: Date?

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            // Standard spoked progress indicator (NSProgressIndicator
            // under the hood), scaled up to read from across the room.
            // Replaced an earlier hand-rolled rotating magnifying-glass
            // animation that read more like a UI bug than a spinner.
            ProgressView()
                .controlSize(.large)
                .scaleEffect(1.6)
                .frame(height: 56)
            VStack(spacing: 6) {
                if let started = startedAt {
                    TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                        let secs = max(0, Int(ctx.date.timeIntervalSince(started)))
                        Text("Searching… +\(secs)s")
                            .font(.headline)
                            .monospacedDigit()
                    }
                } else {
                    Text("Searching…")
                        .font(.headline)
                }
                Text("Looking for “\(query)”")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
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

// MARK: - Import drop

/// Tag an outgoing card drag with our private UTI so the LibraryView's
/// drop delegate can filter it out (otherwise picking up a card briefly
/// flashes the import overlay). Uses `.ownProcess` visibility so external
/// apps never see this type — they only see the regular `.fileURL`
/// representation already on the provider.
func tagAsInternalDrag(_ provider: NSItemProvider) {
    provider.registerDataRepresentation(
        forTypeIdentifier: UTType.refVaultInternalCardDrag.identifier,
        visibility: .ownProcess
    ) { completion in
        completion(Data(), nil)
        return nil
    }
}

private struct LibraryImportDropDelegate: DropDelegate {
    @Binding var isTargeted: Bool
    let coordinator: IngestionCoordinator

    private static let imageExt: Set<String> = [
        "png", "jpg", "jpeg", "heic", "webp",
    ]

    func validateDrop(info: DropInfo) -> Bool {
        // Reject our own card drags so the overlay doesn't flash when the
        // user picks up a card and pauses over the library.
        if info.hasItemsConforming(to: [.refVaultInternalCardDrag]) {
            return false
        }
        return info.hasItemsConforming(to: [.fileURL])
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        isTargeted = true
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        validateDrop(info: info)
            ? DropProposal(operation: .copy)
            : DropProposal(operation: .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        guard validateDrop(info: info) else { return false }
        let providers = info.itemProviders(for: [.fileURL])
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                guard Self.imageExt.contains(url.pathExtension.lowercased()) else {
                    return
                }
                Task { @MainActor in
                    coordinator.enqueue(url)
                }
            }
        }
        return true
    }
}

private struct ImportDropOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down.fill")
                    .font(.system(size: 48, weight: .light))
                    .foregroundColor(.white.opacity(0.95))
                Text("Drop image to add")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
                    .foregroundColor(.white.opacity(0.55))
            )
        }
        .allowsHitTesting(false)
    }
}
