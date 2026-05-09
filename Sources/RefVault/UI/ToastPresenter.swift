import AppKit
import SwiftUI

/// Borderless transparent panel that hosts a `ToastView`, anchored to the
/// bottom-right of the screen, above the dock.
///
/// Uses `NSScreen.main?.visibleFrame`, which already excludes the dock and
/// menu bar regardless of dock orientation (bottom / left / right) or
/// auto-hide state, so we can pin to `visibleFrame` corners with a fixed
/// inset and not have to query the dock geometry directly.
final class ToastPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 96),
            // .nonactivatingPanel is the difference between this and the
            // popover. The popover is interactive (search field, button
            // gestures) and intentionally takes focus. The toast is a
            // notification — taking focus would yank the user out of
            // whatever they're doing AND tie the panel back to the
            // regular per-Space window stack, which is exactly what
            // breaks cross-desktop visibility.
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovable = false
        isReleasedWhenClosed = false
        isFloatingPanel = true
        // Don't disappear when the app deactivates — the whole point of
        // the toast is that it shows regardless of who has focus.
        hidesOnDeactivate = false
        // Match the popover's level. Real cross-Space + above-fullscreen
        // placement comes from joining NotchSpaceManager's custom CGS
        // space at Int32.max - 2; the NSWindow level only matters as a
        // fallback for sandboxed builds where CGS isn't available.
        level = .mainMenu + 3
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
    }

    // Notification panel must NOT become key — would steal focus from
    // whatever the user is doing and re-tie the panel to the active
    // Space, undoing the CGS-space cross-Space placement.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view used by the toast: dismisses the toast on any mouse click.
/// Without this, click-to-dismiss wouldn't work — SwiftUI gesture
/// recognizers don't fire reliably on a non-key non-activating panel
/// (that's the trade-off for true notification behavior). Click-anywhere
/// is also nicer UX than a tiny ×.
final class ToastHostingView<Content: View>: NSHostingView<Content> {
    var onMouseDown: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
        // Intentionally not forwarding to super — the entire toast is a
        // dismiss target, no need for SwiftUI to also process the event.
    }
}

/// Owns a single bottom-right toast panel. New toasts replace the current
/// one and reset the auto-dismiss timer — much simpler than stacking, and
/// the in-toast "X in queue" copy already tells the user there's more.
@MainActor
final class ToastPresenter: NSObject, ObservableObject {
    let panel = ToastPanel()

    @Published private(set) var isVisible = false
    private var current: ToastPayload?
    private var dismissTask: Task<Void, Never>?
    private var spaceChangeObserver: NSObjectProtocol?

    /// Inset from the bottom-right of `visibleFrame`. visibleFrame already
    /// excludes the dock, so 16pt here lands ~16pt above the dock.
    private let edgeInset: CGFloat = 16
    private let toastSize = CGSize(width: 340, height: 96)
    private let visibleSeconds: TimeInterval = 4.0

    override init() {
        super.init()
        // When the user switches Mission Control Space, panels that were
        // orderFront-ed before the switch can fall behind the new active
        // Space's window stack. Re-attach to our custom CGS space and
        // re-promote the panel so it stays visible across desktops + over
        // fullscreen apps.
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reattachToCurrentSpace()
            }
        }
    }

    deinit {
        if let obs = spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }

    /// Show or refresh the toast with new content. Resets the auto-dismiss
    /// timer. If a toast is already on-screen its content cross-fades.
    func show(_ payload: ToastPayload) {
        log("show called style=\(payload.style) layout=\(payload.layout) tags=\(payload.tags.count)")
        current = payload
        rebuildContent(for: payload)

        if isVisible {
            // Already on-screen — just bump the dismiss timer. The SwiftUI
            // tree updates in place because rebuildContent assigns a new
            // rootView with the latest payload.
            log("refresh existing toast (already visible)")
            scheduleDismiss()
            return
        }

        guard let screen = NSScreen.main else {
            log("ERROR: NSScreen.main is nil — cannot place toast")
            return
        }
        let endRect = targetRect(in: screen)
        // Start fully off-screen to the right and slide left into place.
        // Matches the system notification banner motion (which also slides
        // in from the right edge and slides back out the same way).
        let startRect = endRect.offsetBy(dx: endRect.width + edgeInset, dy: 0)

        log("placing toast at \(NSStringFromRect(endRect)) on screen visibleFrame=\(NSStringFromRect(screen.visibleFrame))")
        panel.setFrame(startRect, display: true)
        panel.alphaValue = 0

        // Add to our custom CGS space FIRST, then orderFrontRegardless.
        // Order matters: orderFrontRegardless on a window that's already
        // in the high-level CGS space lands it on top globally; the
        // reverse order can momentarily insert it into the active Space's
        // window stack, where it would inherit normal per-Space scoping.
        var members = NotchSpaceManager.shared.notchSpace.windows
        members.insert(panel)
        NotchSpaceManager.shared.notchSpace.windows = members
        log("joined notchSpace, members=\(NotchSpaceManager.shared.notchSpace.windows.count)")

        // orderFrontRegardless instead of makeKeyAndOrderFront. The
        // earlier makeKeyAndOrderFront approach worked for the popover
        // (which is interactive and wants focus) but for a notification
        // it activated RefVault, stole focus from whatever app was in
        // front, and re-attached the panel to the regular per-Space
        // window stack — which is exactly what was hiding it on other
        // Spaces and over fullscreen apps. Regardless avoids all that
        // and lets the CGS-space level do the actual placement.
        panel.orderFrontRegardless()
        log("orderFrontRegardless called — panel sits at CGS Int32.max-2 level on every Space")

        isVisible = true

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            // Spring-ish ease-out: fast start that settles. Matches the
            // system banner slide more closely than a plain ease-out.
            ctx.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.22, 1.0, 0.30, 1.0
            )
            panel.animator().setFrame(endRect, display: true)
            panel.animator().alphaValue = 1
        }

        scheduleDismiss()
    }

    /// Dismiss the toast immediately (e.g. user clicked the close button).
    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        guard isVisible else { return }

        // Slide back out to the right (off-screen) — symmetrical with the
        // entry animation and matches the system notification dismissal.
        let collapseRect = panel.frame.offsetBy(dx: panel.frame.width + edgeInset, dy: 0)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.4, 0.0, 0.7, 1.0
            )
            panel.animator().setFrame(collapseRect, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                var members = NotchSpaceManager.shared.notchSpace.windows
                members.remove(self.panel)
                NotchSpaceManager.shared.notchSpace.windows = members
                self.panel.orderOut(nil)
                self.isVisible = false
                self.current = nil
            }
        })
    }

    // MARK: Private

    private func targetRect(in screen: NSScreen) -> NSRect {
        let v = screen.visibleFrame
        return NSRect(
            x: v.maxX - toastSize.width - edgeInset,
            y: v.minY + edgeInset,
            width: toastSize.width,
            height: toastSize.height
        )
    }

    private func rebuildContent(for payload: ToastPayload) {
        let view = ToastView(payload: payload)
        let host = ToastHostingView(rootView: AnyView(view))
        host.onMouseDown = { [weak self] in self?.dismiss() }
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    /// Re-pin the panel to our CGS space and re-promote it. Called when
    /// the user switches Mission Control Spaces — without this, a toast
    /// that was on screen on Desktop 1 won't follow the user to Desktop 2.
    private func reattachToCurrentSpace() {
        guard isVisible else { return }
        var members = NotchSpaceManager.shared.notchSpace.windows
        members.insert(panel)
        NotchSpaceManager.shared.notchSpace.windows = members
        panel.orderFrontRegardless()
        log("Space changed — re-attached panel, members=\(NotchSpaceManager.shared.notchSpace.windows.count)")
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(4.0 * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.dismiss() }
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[Toast] \(message)\n".utf8))
    }
}
