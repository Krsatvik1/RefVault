import AppKit
import SwiftUI

/// Borderless transparent panel that hosts the dynamic-island view, anchored
/// to the top center of the screen so it appears to grow out of the notch.
final class IslandPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            // No `.nonactivatingPanel`. We intentionally let the app
            // activate when the panel is clicked — that's how
            // boring.notch / SkyLightWindow handle it, and it's required
            // for SwiftUI Button gestures to complete (a non-key,
            // non-activating panel doesn't promote subviews into the
            // tap-tracking state machine, so mouseUp never reaches the
            // gesture and the action callback never fires).
            styleMask: [.borderless, .fullSizeContentView],
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
        // NSWindow.level can't punch through the menu bar — that's a hard
        // cap by the WindowServer. The actual mechanism that puts this
        // panel above the menu bar is `NotchSpaceManager.shared.notchSpace`,
        // a custom CGS space at `Int32.max - 2` absolute level. Setting a
        // high panel level here is just so the panel sits above ordinary
        // windows when CGS isn't available (sandboxed builds).
        level = .mainMenu + 3
        collectionBehavior = [
            .fullScreenAuxiliary,
            .stationary,
            .canJoinAllSpaces,
            .ignoresCycle,
        ]
    }

    /// Must both return true so SwiftUI Buttons inside the panel can
    /// complete their tap gestures. `canBecomeMain = true` is needed in
    /// addition to `canBecomeKey` because some AppKit gesture-tracking
    /// paths only kick in when the window participates as a main window
    /// candidate (boring.notch / SkyLightWindow ship with both true).
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// NSHostingView subclass that returns `true` from `acceptsFirstMouse(for:)`.
/// Required because IslandPanel can't become key (`canBecomeKey = false`),
/// and AppKit eats mouse-down events on non-key windows unless the content
/// view opts in via this hook. Without it SwiftUI Buttons inside the
/// island never see clicks.
///
/// Also pins `safeAreaInsets` to zero. Without this, NSHostingView keeps
/// invalidating its safeAreaCornerInsets during the panel's frame animation
/// — each invalidation triggers another constraint pass, AppKit caps the
/// number of passes per window, and the next pass throws NSGenericException.
/// The island doesn't sit under any system chrome (it's borderless), so
/// zero insets are correct.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var safeAreaInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
}

/// Owns the status item button + the island panel, and handles the open/close
/// animation. The animation grows the window's frame from a notch-sized pill
/// down to the full panel, so visually it reads as "the notch is unfolding".
@MainActor
final class IslandPresenter: NSObject, ObservableObject {
    let panel = IslandPanel()

    @Published private(set) var isVisible = false

    /// Notch-sized starting pill — width matches a typical M-series notch
    /// and height matches the menu bar so it perfectly hides under it.
    private let compactSize = CGSize(width: 220, height: 32)
    /// Fully expanded island height. Width is computed from the screen so
    /// the panel spans edge to edge. Sized to fit the V1 layout: menu-bar
    /// strip (30) + search (32) + filter row (~28) + result rail (154) +
    /// scroll track (14) + gaps + padding.
    private let fullHeight: CGFloat = 320

    func setContent<V: View>(_ view: V) {
        let host = FirstMouseHostingView(rootView: AnyView(view))
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        guard let screen = NSScreen.main else { return }

        let frame = screen.frame
        let centerX = frame.midX

        let startRect = NSRect(
            x: centerX - compactSize.width / 2,
            y: frame.maxY - compactSize.height,
            width: compactSize.width,
            height: compactSize.height
        )
        let endRect = NSRect(
            x: frame.minX,
            y: frame.maxY - fullHeight,
            width: frame.width,
            height: fullHeight
        )

        panel.setFrame(startRect, display: true)
        panel.alphaValue = 0
        panel.orderFront(nil)

        // Move the panel into the custom CGS space. This is the trick that
        // actually places the window above the menu bar.
        var members = NotchSpaceManager.shared.notchSpace.windows
        members.insert(panel)
        NotchSpaceManager.shared.notchSpace.windows = members

        // Promote to key AFTER joining the space — this is the order
        // boring.notch / SkyLightWindow use. Without it, SwiftUI Button
        // gestures can't complete because the panel never becomes key.
        panel.makeKeyAndOrderFront(nil)

        isVisible = true

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.32
            ctx.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.32, 1.42, 0.5, 1.0
            )
            panel.animator().setFrame(endRect, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let screen = NSScreen.main else {
            panel.orderOut(nil)
            isVisible = false
            return
        }
        let frame = screen.frame
        let centerX = frame.midX
        let collapseRect = NSRect(
            x: centerX - compactSize.width / 2,
            y: frame.maxY - compactSize.height,
            width: compactSize.width,
            height: compactSize.height
        )

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(collapseRect, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Pop the panel out of the custom space, then order out.
                var members = NotchSpaceManager.shared.notchSpace.windows
                members.remove(self.panel)
                NotchSpaceManager.shared.notchSpace.windows = members
                self.panel.orderOut(nil)
                self.isVisible = false
            }
        })
    }
}
