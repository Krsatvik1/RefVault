import AppKit
import SwiftUI

/// Borderless transparent panel that hosts the dynamic-island view, anchored
/// to the top center of the screen so it appears to grow out of the notch.
final class IslandPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            // `.nonactivatingPanel` is what makes this panel actually
            // appear when the user is in another app's fullscreen Space
            // (e.g. fullscreen Ghostty). Without it, AppKit treats the
            // panel as a normal interactive window — and since clicking
            // the menu bar item from a fullscreen Space doesn't activate
            // RefVault into that Space, NSPanel's hidesOnDeactivate
            // immediately strips the panel from our CGS notchSpace and
            // hides it. The toast had the exact same bug.
            //
            // Trade-off the old comment warned about: with
            // `.nonactivatingPanel`, SwiftUI Button gestures can be
            // unreliable because the panel's subviews aren't promoted
            // into the tap-tracking state machine until the panel is
            // key. We compensate below by keeping canBecomeKey=true and
            // calling makeKey() in show() — that lets SwiftUI gestures
            // fire from our regular Space, and from a fullscreen Space
            // the first user click on the panel promotes it (via
            // acceptsFirstMouse on the hosting view).
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
        // Don't disappear when RefVault deactivates — the whole point of
        // the popover is that it shows over whatever app is in front,
        // including fullscreen apps where RefVault never gets activated.
        // NSPanel defaults this to true; that's what was hiding the panel
        // in another app's fullscreen Space.
        hidesOnDeactivate = false
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

    /// Resolver for the screen the popover should anchor to. Set by the
    /// app delegate to the status item's window screen — `NSScreen.main`
    /// is the screen with the key window, NOT the screen the user clicked
    /// the menu bar on, so it returns the wrong display (or nil) when a
    /// fullscreen app is active or the menu bar is on a secondary monitor.
    var screenResolver: (() -> NSScreen?)?

    /// Screen the panel is currently anchored to. Captured at show() time
    /// so hide()'s collapse animation lands on the same display even if
    /// focus moved between show and hide.
    private var anchoredScreen: NSScreen?

    private var spaceChangeObserver: NSObjectProtocol?

    override init() {
        super.init()
        // Without this, switching Mission Control Spaces (especially in/out
        // of a fullscreen app on a secondary display) leaves the popover
        // stranded behind the new active Space's window stack. Toast had
        // the same bug — fix is the same: re-pin to our CGS space and
        // re-promote when the active Space changes.
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

    private func resolveScreen() -> NSScreen? {
        let resolverScreen = screenResolver?()
        let mouse = NSEvent.mouseLocation
        let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
        let mainScreen = NSScreen.main
        let allScreens = NSScreen.screens.enumerated().map { i, s in
            "\(i):\(NSStringFromRect(s.frame))"
        }.joined(separator: " | ")
        FileHandle.standardError.write(Data(
            "[Island] resolveScreen — resolver=\(resolverScreen.map { NSStringFromRect($0.frame) } ?? "nil") mouse=\(NSStringFromPoint(mouse)) mouseScreen=\(mouseScreen.map { NSStringFromRect($0.frame) } ?? "nil") main=\(mainScreen.map { NSStringFromRect($0.frame) } ?? "nil") all=[\(allScreens)]\n".utf8
        ))
        if let s = resolverScreen { return s }
        if let s = mouseScreen { return s }
        return mainScreen ?? NSScreen.screens.first
    }

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
        FileHandle.standardError.write(Data(
            "[Island] show() called — isVisible=\(isVisible) panel.isVisible=\(panel.isVisible)\n".utf8
        ))
        guard let screen = resolveScreen() else {
            FileHandle.standardError.write(Data(
                "[Island] show() — no screen resolvable, aborting\n".utf8
            ))
            return
        }
        anchoredScreen = screen
        FileHandle.standardError.write(Data(
            "[Island] show() anchoring to screen frame=\(NSStringFromRect(screen.frame)) visibleFrame=\(NSStringFromRect(screen.visibleFrame))\n".utf8
        ))

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

        // Join the custom CGS space FIRST. orderFrontRegardless after
        // joining keeps the panel in our notchSpace at Int32.max-2 (above
        // every Space, including other apps' fullscreen Spaces).
        //
        // Earlier we used makeKeyAndOrderFront here, which re-orders the
        // panel into the *regular per-Space* window stack. When the user
        // clicks our menu bar item from inside another app's fullscreen
        // Space (e.g. fullscreen Ghostty), that "regular Space" for
        // RefVault is its own Desktop 1 — so the panel gets placed there
        // and is invisible to the user in Ghostty's Space. Symptom in the
        // log: panel.isKey=false in the failing case (key promotion is
        // denied across fullscreen-app Space boundaries) but panel.isVisible
        // is true on a Space the user can't see.
        //
        // orderFrontRegardless avoids both problems: doesn't trigger app
        // activation (so user stays in their fullscreen Space) and doesn't
        // re-attach to the regular Space stack (so notchSpace membership
        // sticks). Trade-off: panel doesn't become key automatically. The
        // first click on the panel (via acceptsFirstMouse on the hosting
        // view) brings RefVault forward and promotes the panel to key,
        // which is when SwiftUI Button gestures + the search field start
        // accepting input. This matches how Spotlight / Raycast feel from
        // a fullscreen Space.
        var members = NotchSpaceManager.shared.notchSpace.windows
        members.insert(panel)
        NotchSpaceManager.shared.notchSpace.windows = members
        FileHandle.standardError.write(Data(
            "[Island] show() — joined notchSpace, members=\(NotchSpaceManager.shared.notchSpace.windows.count)\n".utf8
        ))

        panel.orderFrontRegardless()
        FileHandle.standardError.write(Data(
            "[Island] show() — after orderFrontRegardless, panel.frame=\(NSStringFromRect(panel.frame)) panel.screen=\(panel.screen.map { NSStringFromRect($0.frame) } ?? "nil") panel.isVisible=\(panel.isVisible) panel.isKey=\(panel.isKeyWindow)\n".utf8
        ))

        // Try to promote to key WITHOUT re-ordering. makeKey doesn't move
        // the window in the screen list — only flips key status. If we're
        // in our own Space this succeeds and SwiftUI gestures fire
        // immediately; if we're in another app's fullscreen Space the OS
        // denies the promotion silently and the first user click on the
        // panel handles it instead.
        panel.makeKey()
        FileHandle.standardError.write(Data(
            "[Island] show() — after makeKey, panel.isKey=\(panel.isKeyWindow)\n".utf8
        ))

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
        // Use the screen we anchored to in show(); falling back to a
        // freshly-resolved one keeps the collapse animation correct even
        // if the resolver's source (status item button) has gone away.
        guard let screen = anchoredScreen ?? resolveScreen() else {
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
                self.anchoredScreen = nil
            }
        })
    }

    /// Re-pin to our CGS space + re-promote when the user switches Mission
    /// Control Spaces. Without this, a popover left open while the user
    /// swipes to another desktop or enters a fullscreen app falls behind
    /// the new Space's window stack and is invisible until next click.
    private func reattachToCurrentSpace() {
        guard isVisible else { return }
        var members = NotchSpaceManager.shared.notchSpace.windows
        members.insert(panel)
        NotchSpaceManager.shared.notchSpace.windows = members
        panel.orderFrontRegardless()
        // Re-key so SwiftUI gestures (search field, sort menu, tag chips)
        // still fire on the new Space. orderFrontRegardless alone is
        // enough for the toast (no gestures), but the popover needs key.
        panel.makeKey()
    }
}
