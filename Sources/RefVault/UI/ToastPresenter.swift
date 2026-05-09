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

    // Allow key / main so reattachToCurrentSpace can call makeKey() on
    // a Space change. The combination of `.nonactivatingPanel` +
    // `hidesOnDeactivate = false` already prevents the toast from
    // activating RefVault or stealing keyboard input from the foreground
    // app — makeKey here just anchors the panel to the WindowServer's
    // redraw schedule across the Space transition so it re-composites
    // inside the same frame as the swipe instead of flickering.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Hosting view used by the toast: routes mouse-down to one of two
/// closures. Click inside `saveAnywayHitRect` (when set) → `onSaveAnyway`;
/// any other click → `onMouseDown` (toast dismiss). SwiftUI gesture
/// recognizers don't fire reliably on a non-key non-activating panel,
/// so the button needs an explicit AppKit hit-test.
final class ToastHostingView<Content: View>: NSHostingView<Content> {
    var onMouseDown: (() -> Void)?
    var onSaveAnyway: (() -> Void)?
    /// Rect (in this view's local coords, bottom-left origin) that, when
    /// hit, fires onSaveAnyway instead of onMouseDown.
    var saveAnywayHitRect: CGRect?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
    override func mouseDown(with event: NSEvent) {
        let local = self.convert(event.locationInWindow, from: nil)
        if let hit = saveAnywayHitRect, hit.contains(local) {
            FileHandle.standardError.write(Data(
                "[Toast] mouseDown HIT save-anyway at \(NSStringFromPoint(local)) (rect=\(NSStringFromRect(hit)))\n".utf8
            ))
            onSaveAnyway?()
        } else {
            FileHandle.standardError.write(Data(
                "[Toast] mouseDown DISMISS at \(NSStringFromPoint(local)) (rect=\(saveAnywayHitRect.map { NSStringFromRect($0) } ?? "nil"))\n".utf8
            ))
            onMouseDown?()
        }
        // Intentionally not forwarding to super.
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
    private let toastWidth: CGFloat = 340
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
        let h = current?.preferredHeight ?? 96
        return NSRect(
            x: v.maxX - toastWidth - edgeInset,
            y: v.minY + edgeInset,
            width: toastWidth,
            height: h
        )
    }

    private func rebuildContent(for payload: ToastPayload) {
        let view = ToastView(payload: payload)
        let host = ToastHostingView(rootView: AnyView(view))
        host.onMouseDown = { [weak self] in self?.dismiss() }
        // Wire the save-anyway button hit zone for duplicate toasts.
        // CRITICAL: NSHostingView is FLIPPED by default to match SwiftUI's
        // top-left origin, so the local point we get from convert(_:from:)
        // in mouseDown is also top-left. Earlier I'd set this rect using
        // bottom-left math (y=10 = "10pt up from the bottom"), which put
        // the hit zone at the top of the view in flipped coords — every
        // click landed in DISMISS instead. Top-left coords here:
        //   button sits at y = 162(panel) - 10(pad) - 44(button) = 108
        if case let .duplicate(_, _, _, onSaveAnyway) = payload.kind,
           !payload.saveAnywaySubmitted {
            let panelH: CGFloat = 162
            let pad: CGFloat = 10
            let buttonH: CGFloat = 44
            host.saveAnywayHitRect = CGRect(
                x: pad,
                y: panelH - pad - buttonH,
                width: 340 - pad * 2,
                height: buttonH
            )
            host.onSaveAnyway = { [weak self] in
                guard let self else { return }
                onSaveAnyway()
                // Visual ack: flip the button to a greyed "Indexing…"
                // state, kill further clicks, then auto-dismiss after
                // a beat so the user sees the click landed before the
                // toast slides away.
                self.markSubmittedAndDismissShortly()
            }
        } else {
            // Either not a duplicate, or already submitted — no
            // interactive button. Disable the hit zone so further
            // clicks fall through to the dismiss handler.
            host.saveAnywayHitRect = nil
            host.onSaveAnyway = nil
        }
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
        // Match the island: makeKey after orderFrontRegardless on Space
        // change. Without this the toast briefly disappears and re-
        // composites during fullscreen-app swipes — the WindowServer
        // un-layers the panel during the transition and our reattach
        // happens in the next frame. makeKey ties the redraw to the
        // same frame as the Space change so the re-composite is
        // invisible. Safe because `.nonactivatingPanel` keeps RefVault
        // from activating, and `canBecomeKey = true` (in ToastPanel)
        // doesn't pull keyboard input away from the foreground app —
        // that's controlled by app activation, not key window status.
        panel.makeKey()
        log("Space changed — re-attached panel, members=\(NotchSpaceManager.shared.notchSpace.windows.count)")
    }

    /// Mutates `current` to the submitted state, rebuilds the SwiftUI
    /// content (button now reads "Indexing…", greyed, no hit zone), then
    /// kicks off a short auto-dismiss so the user sees the ack before the
    /// toast slides off-screen.
    private func markSubmittedAndDismissShortly() {
        guard var p = current else { return }
        p.saveAnywaySubmitted = true
        current = p
        rebuildContent(for: p)

        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(0.9 * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.dismiss() }
        }
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
