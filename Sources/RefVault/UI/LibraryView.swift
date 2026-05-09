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
            ActivityBar()
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
        VStack(alignment: .leading, spacing: 10) {
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
        if let filter = parsedFilter, parsedFilterFor == query, !filter.isEmpty {
            return store.search(filter: filter)
        }
        return store.search(query)
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
            ZStack {
                Color.secondary.opacity(0.1)
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
            .frame(height: 140)
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
            if isRegenerating {
                Text("queued")
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(rosePrimary))
                    .padding(8)
            }
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

/// Compact panel showing what's processing now and what's queued. Hidden
/// when nothing is in flight and the queue is empty.
struct ActivityBar: View {
    @EnvironmentObject var coordinator: IngestionCoordinator

    var body: some View {
        if coordinator.inFlight == nil && coordinator.pending.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    if let url = coordinator.inFlight {
                        ProgressView()
                            .controlSize(.small)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Indexing")
                                .font(.caption2.weight(.semibold))
                                .foregroundColor(.secondary)
                            Text(url.lastPathComponent)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    Spacer()
                    if !coordinator.pending.isEmpty {
                        Text("\(coordinator.pending.count) queued")
                            .font(.caption.weight(.medium))
                            .foregroundColor(.secondary)
                        Button("Clear queue") { coordinator.clearPending() }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                }

                if !coordinator.pending.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(coordinator.pending, id: \.self) { url in
                                QueueChip(url: url) {
                                    coordinator.cancel(url)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.06))
        }
    }
}

private struct QueueChip: View {
    let url: URL
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(url.lastPathComponent)
                .font(.caption2.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.15))
        .cornerRadius(6)
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
