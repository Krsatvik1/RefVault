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
        Group {
            if case let .duplicate(newURL, matches, _, _) = payload.kind {
                duplicateBody(newURL: newURL, matches: matches)
            } else {
                regularBody
            }
        }
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

    // MARK: Regular body (saved + refreshed)

    private var regularBody: some View {
        HStack(alignment: .bottom, spacing: 10) {
            thumbnail
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                header
                tagsRow
                statusRow
            }
            .frame(maxWidth: .infinity, alignment: .bottomLeading)
        }
        .padding(10)
        .frame(width: 340, height: 96, alignment: .bottomLeading)
    }

    // MARK: Duplicate body (T3 layout)

    private func duplicateBody(newURL: URL, matches: [URL]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Headline + decorative ×
            HStack(spacing: 8) {
                Text("Already in library")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Color(white: 0.95))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color(white: 0.43))
                    .frame(width: 14, height: 14)
            }
            .frame(height: 18)

            duplicateThumbRow(newURL: newURL, matches: matches)

            // Big CTA. Hit-tested in ToastHostingView so click routes
            // through onSaveAnyway instead of the dismiss closure.
            saveAnywayButton
        }
        .padding(10)
        // Height = 10 + 18 + 10 + 60 + 10 + 44 + 10 = 162pt. Must match
        // ToastPayload.preferredHeight so the panel sizes correctly.
        .frame(width: 340, height: 162, alignment: .topLeading)
    }

    private func duplicateThumbRow(newURL: URL, matches: [URL]) -> some View {
        let visibleMatches = Array(matches.prefix(3))
        let overflow = max(0, matches.count - visibleMatches.count)
        return HStack(spacing: 6) {
            duplicateThumb(url: newURL, isNew: true)
            ForEach(visibleMatches, id: \.self) { url in
                duplicateThumb(url: url, isNew: false)
            }
            if overflow > 0 {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(
                            Color.white.opacity(0.10),
                            style: StrokeStyle(lineWidth: 1, dash: [3, 3])
                        )
                    Text("+\(overflow)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color(white: 0.55))
                }
                .frame(width: 30, height: 60)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 60)
    }

    @ViewBuilder
    private func duplicateThumb(url: URL, isNew: Bool) -> some View {
        let blue = Color(red: 0.31, green: 0.55, blue: 0.96)
        ZStack(alignment: .topTrailing) {
            Group {
                if let img = NSImage(contentsOf: url) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
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
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isNew ? blue : Color.white.opacity(0.06),
                            lineWidth: isNew ? 2 : 1)
            )

            if isNew {
                Text("NEW")
                    .font(.system(size: 8, weight: .bold))
                    .tracking(0.6)
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(blue)
                    )
                    .offset(x: 4, y: -6)
            }
        }
        .frame(width: 60, height: 60)
    }

    private var saveAnywayButton: some View {
        let submitted = payload.saveAnywaySubmitted
        let bgColor = submitted
            ? Color.white.opacity(0.10)
            : Color(red: 0.98, green: 0.98, blue: 0.98)
        let fgColor = submitted
            ? Color.white.opacity(0.55)
            : Color(red: 0.122, green: 0.122, blue: 0.133)
        let icon = submitted ? "hourglass" : "arrow.down.to.line"
        let label = submitted ? "Indexing…" : "Save it regardless"
        return HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(fgColor)
            Text(label)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundColor(fgColor)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(bgColor)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    submitted
                        ? Color.white.opacity(0.10)
                        : Color.white.opacity(0.4),
                    lineWidth: 0.5
                )
                .blendMode(.overlay)
        )
        .shadow(color: .black.opacity(submitted ? 0 : 0.18), radius: 2, x: 0, y: 1)
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
        // Three states: green/saved (fresh ingest), amber/refreshed
        // (regenerate), blue/already in library (duplicate skip).
        let dotColor: Color
        let verb: String
        switch payload.kind {
        case .ingest:
            dotColor = Color(red: 0.20, green: 0.78, blue: 0.35)
            verb = "saved"
        case .regenerate:
            dotColor = Color(red: 1.00, green: 0.62, blue: 0.04)
            verb = "refreshed"
        case .duplicate(_, _, let hamming, _):
            // statusRow only renders for the regular body; the duplicate
            // body has its own headline ("Already in library") and
            // doesn't surface this row. Kept here so the switch is
            // exhaustive and the Color/String are always defined.
            dotColor = Color(red: 0.31, green: 0.55, blue: 0.96)
            if let h = hamming {
                verb = "already saved (≈\(h)b diff)"
            } else {
                verb = "already saved"
            }
        }
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
struct ToastPayload {
    enum Kind {
        case ingest
        case regenerate
        /// User dropped an image we already have.
        /// - newImageURL: the just-dropped file (rendered as the highlighted
        ///   "NEW" thumbnail in the duplicate toast).
        /// - matches: every existing record the new image collided with,
        ///   nearest-first.
        /// - hamming: nil for exact-byte matches, the Hamming distance for
        ///   visual matches.
        /// - onSaveAnyway: fires when the user clicks "Save it regardless".
        case duplicate(
            newImageURL: URL,
            matches: [URL],
            hamming: Int?,
            onSaveAnyway: () -> Void
        )

        var isDuplicate: Bool {
            if case .duplicate = self { return true }
            return false
        }
    }

    var thumbnailURL: URL?
    var style: String
    var layout: String
    var tags: [String]
    var processingSeconds: Double?
    var queueCount: Int
    var kind: Kind = .ingest
    /// Set to true after the user clicks "Save it regardless" — the
    /// duplicate toast then renders the button greyed out with
    /// "Indexing…" until the toast auto-dismisses.
    var saveAnywaySubmitted: Bool = false

    /// Toasts have different intrinsic heights — the duplicate variant
    /// needs room for the thumb row + the big CTA button below the
    /// header. Must match the .frame() height in the corresponding
    /// ToastView body branch (otherwise the panel and the rendered
    /// content disagree and you get clipping or empty bands).
    var preferredHeight: CGFloat {
        switch kind {
        case .duplicate: return 162
        default: return 96
        }
    }
}

private extension String {
    var capitalizingFirst: String {
        guard let first = first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
