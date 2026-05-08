import SwiftUI
import AppKit

struct DetailView: View {
    let record: ScreenshotRecord
    @EnvironmentObject var store: LibraryStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 0) {
            // Image
            ZStack {
                Color.black.opacity(0.85)
                if let url = store.storedImageURL(for: record),
                   let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(20)
                } else {
                    Text("Image missing")
                        .foregroundColor(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Metadata column
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Spacer()
                        Button("Close") { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }

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
                        Text(String(format: "Confidence %.0f%%", record.relevance.confidence * 100))
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                    }

                    if let m = record.metadata {
                        Divider()
                        Text("Design")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                        kv("Style", m.style)
                        kv("Typography", m.typography)
                        kv("Layout", m.layout)
                        kv("Mood", m.mood)
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
                        HStack(spacing: 8) {
                            ForEach(Array(p.all.enumerated()), id: \.offset) { _, hex in
                                VStack(spacing: 4) {
                                    ColorSwatch(hex: hex, size: 28)
                                    Text(hex.uppercased())
                                        .font(.caption2.monospaced())
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
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
            .frame(width: 320)
            .background(Color.secondary.opacity(0.04))
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
