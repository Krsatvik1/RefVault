import SwiftUI
import AppKit

struct LibraryView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var coordinator: IngestionCoordinator
    @EnvironmentObject var watcher: ScreenshotWatcher

    @State private var query: String = ""
    @State private var selectedRecord: ScreenshotRecord?

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 16)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .sheet(item: $selectedRecord) { rec in
            DetailView(record: rec)
                .frame(minWidth: 720, minHeight: 520)
        }
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
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search tags, style, surface, device…", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(Color.secondary.opacity(0.08))
            .cornerRadius(8)
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        let results = store.search(query)
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

struct LibraryCard: View {
    let record: ScreenshotRecord
    @EnvironmentObject var store: LibraryStore

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
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
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
