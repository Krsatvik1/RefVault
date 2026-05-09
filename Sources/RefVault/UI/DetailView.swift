import SwiftUI
import AppKit

struct DetailView: View {
    let record: ScreenshotRecord
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var coordinator: IngestionCoordinator
    @Environment(\.dismiss) private var dismiss

    private var isRegenerating: Bool {
        coordinator.regeneratingIds.contains(record.id)
    }

    private func formatProcessingTime(_ s: Double) -> String {
        if s < 60 { return String(format: "%.1fs", s) }
        let m = Int(s) / 60
        let r = s - Double(m * 60)
        return String(format: "%dm %.0fs", m, r)
    }

    var body: some View {
        // The outer GeometryReader bounds the whole sheet so the metadata
        // ScrollView never pushes the sheet's intrinsic height past the
        // viewport — that was leaving the image stranded in unbounded space.
        GeometryReader { geo in
            HStack(spacing: 0) {
                imagePane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                metadataPane
                    .frame(width: 360)
                    .frame(maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.04))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: - Image pane

    private var imagePane: some View {
        ZStack {
            Color.black.opacity(0.92)
            if let url = store.storedImageURL(for: record),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(16)
            } else {
                Text("Image missing")
                    .foregroundColor(.white.opacity(0.6))
            }
        }
    }

    // MARK: - Metadata pane

    private var metadataPane: some View {
        VStack(spacing: 0) {
            // Sticky header so Close + Regenerate are always reachable while
            // the metadata scrolls.
            HStack {
                Button {
                    coordinator.regenerate(record)
                    dismiss()
                } label: {
                    if isRegenerating {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Queued — regenerating…")
                        }
                    } else {
                        Label("Regenerate", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isRegenerating || store.storedImageURL(for: record) == nil)
                .help("Queue this image for re-evaluation. The card in the library will animate while the agent runs.")

                Spacer()

                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.secondary.opacity(0.05))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Group {
                        Text("Classification")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                        HStack(spacing: 6) {
                            Badge(label: record.relevance.surface, tone: .blue)
                            Badge(label: record.relevance.device, tone: .purple)
                            Badge(label: record.orientation, tone: .gray)
                        }
                        Text(record.relevance.reason)
                            .font(.callout)
                            .foregroundColor(.secondary)
                        HStack(spacing: 12) {
                            Text(String(format: "Confidence %.0f%%", record.relevance.confidence * 100))
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                            if let s = record.processingSeconds {
                                Text("·")
                                    .foregroundColor(.secondary)
                                Text("Indexed in \(formatProcessingTime(s))")
                                    .font(.caption.monospaced())
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    if let m = record.metadata {
                        Divider()
                        Text("Design")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                        kv("Style", m.style)
                        kv("Layout", m.layout)
                        kv("Mood", m.mood)
                        if !m.typography.isEmpty {
                            Text("Typography")
                                .font(.caption.weight(.semibold))
                                .foregroundColor(.secondary)
                                .padding(.top, 4)
                            if !m.typography.headings.isEmpty {
                                kv("Headings", m.typography.headings.joined(separator: ", "))
                            }
                            if !m.typography.bodies.isEmpty {
                                kv("Body", m.typography.bodies.joined(separator: ", "))
                            }
                            if !m.typography.others.isEmpty {
                                kv("Other", m.typography.others.joined(separator: ", "))
                            }
                        }
                        if !m.tags.isEmpty {
                            Text("Tags").font(.caption.weight(.semibold)).foregroundColor(.secondary)
                            FlowingTags(tags: m.tags)
                        }
                    }

                    if let p = record.palette {
                        Divider()
                        Text("Palette")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                        let cols = [GridItem(.adaptive(minimum: 56, maximum: 80), spacing: 8)]
                        LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
                            ForEach(Array(p.all.enumerated()), id: \.offset) { _, hex in
                                VStack(spacing: 3) {
                                    ColorSwatch(hex: hex, size: 28)
                                    Text(ColorNamer.family(for: hex))
                                        .font(.caption2.weight(.medium))
                                    Text(hex.uppercased())
                                        .font(.caption2.monospaced())
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }

                    if let v = record.visibleURL, let urlStr = v.url {
                        Divider()
                        Text("Source URL")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                        Button(urlStr) {
                            let resolved = urlStr.hasPrefix("http") ? urlStr : "https://\(urlStr)"
                            if let url = URL(string: resolved) {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.link)
                    }

                    Divider()
                    Text("Origin")
                        .font(.caption.weight(.semibold))
                        .foregroundColor(.secondary)
                    kv("Source", record.sourceFilePath)
                    kv("Captured", record.capturedAt.formatted())
                    kv("Indexed", record.indexedAt.formatted())
                    kv("Dimensions", "\(record.imageWidth) × \(record.imageHeight)")

                    Divider()
                    Button("Delete from library", role: .destructive) {
                        store.delete(record)
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(20)
            }
        }
    }

    private func kv(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

}

private struct FlowingTags: View {
    let tags: [String]
    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 60, maximum: 200), spacing: 4)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(tags, id: \.self) { tag in
                Text(tag)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12))
                    .cornerRadius(4)
            }
        }
    }
}
