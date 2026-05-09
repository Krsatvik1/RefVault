import SwiftUI
import AppKit

/// Compact "saved" notification card. Mirrors the Paper T1 component:
/// 340 × 96, dark surface, thumbnail on the left, classification + tags +
/// status on the right. Filename is intentionally not shown — the headline
/// is the model's verdict (style + layout), which is what the user actually
/// learns from the notification.
struct ToastView: View {
    let payload: ToastPayload

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnail
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                header
                tagsRow
                statusRow
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(width: 340, height: 96, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.122, green: 0.122, blue: 0.133))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 18, x: 0, y: 12)
    }

    // MARK: Thumbnail

    @ViewBuilder
    private var thumbnail: some View {
        if let url = payload.thumbnailURL,
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            // Fallback gradient when the image hasn't been written yet
            // (toast can fire before LibraryStore.copy completes on slow
            // disks). The palette is derived so it still feels intentional.
            LinearGradient(
                colors: [
                    Color(red: 0.91, green: 0.85, blue: 0.75),
                    Color(red: 0.55, green: 0.42, blue: 0.29),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            // Style + layout, e.g. "Editorial · pricing page"
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(payload.style.capitalizingFirst)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(Color(white: 0.95))
                    .lineLimit(1)
                if !payload.layout.isEmpty {
                    Text("·")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(white: 0.30))
                    Text(payload.layout.replacingOccurrences(of: "-", with: " "))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(Color(white: 0.61))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let secs = payload.processingSeconds {
                Text(String(format: "%.1fs", secs))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(white: 0.43))
            }
            // Decorative — the whole toast is a click-to-dismiss target
            // (mouseDown handled in ToastHostingView). SwiftUI Buttons
            // don't fire reliably on a non-key non-activating panel, and
            // a notification with click-anywhere-to-dismiss is nicer UX
            // than a fiddly 14pt × hit zone.
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(Color(white: 0.43))
                .frame(width: 14, height: 14)
        }
    }

    // MARK: Tags row

    private var tagsRow: some View {
        let visible = Array(payload.tags.prefix(3))
        let overflow = max(0, payload.tags.count - visible.count)
        return HStack(spacing: 4) {
            ForEach(visible, id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(Color(white: 0.78))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    )
            }
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(Color(white: 0.43))
                    .padding(.leading, 2)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Status row

    private var statusRow: some View {
        // Regenerates use amber + "refreshed" so the user can tell at a
        // glance whether they're seeing a fresh import or a re-index.
        let isIngest = payload.kind == .ingest
        let dotColor = isIngest
            ? Color(red: 0.20, green: 0.78, blue: 0.35)   // green
            : Color(red: 1.00, green: 0.62, blue: 0.04)   // amber
        let verb = isIngest ? "saved" : "refreshed"
        return HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
                .overlay(
                    Circle()
                        .stroke(dotColor.opacity(0.18), lineWidth: 2)
                )
            Text(verb)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color(white: 0.55))
            if payload.queueCount > 0 {
                Text("·")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(white: 0.29))
                Text("\(payload.queueCount) in queue")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(Color(white: 0.55))
            }
            Spacer(minLength: 0)
            Text("RefVault")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.7)
                .foregroundColor(Color(white: 0.36))
        }
    }
}

/// View-model for one toast appearance. Built from a saved record at the
/// callsite so the toast presenter never has to reach into LibraryStore.
struct ToastPayload: Equatable {
    enum Kind { case ingest, regenerate }

    var thumbnailURL: URL?
    var style: String
    var layout: String
    var tags: [String]
    var processingSeconds: Double?
    var queueCount: Int
    var kind: Kind = .ingest
}

private extension String {
    var capitalizingFirst: String {
        guard let first = first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
