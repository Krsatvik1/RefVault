import SwiftUI
import AppKit

/// SwiftPM executables run with the default NSApplication activation policy,
/// which is *not* a regular foreground app. The result: the window draws and
/// is clickable, but it never becomes the key window — keystrokes keep going
/// to whatever GUI app was previously focused (Chrome, the terminal, etc).
/// Bumping the activation policy to .regular and force-activating fixes it.
@MainActor
final class RefVaultAppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var island: IslandPresenter?
    var toast: ToastPresenter?
    private var globalDismissMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Replace the default Swift-runner dock icon with our own. Loaded
        // at runtime instead of via Info.plist because SwiftPM executables
        // don't ship an Asset Catalog. PNG @1024 is the recommended source
        // — macOS scales it down for the dock and the application
        // switcher and applies the rounded-square mask itself.
        let appIconURL = Bundle.module.url(
            forResource: "AppIcon",
            withExtension: "png",
            subdirectory: "Resources/icons"
        ) ?? Bundle.module.url(
            forResource: "AppIcon",
            withExtension: "png"
        )
        if let url = appIconURL, let img = NSImage(contentsOf: url) {
            // Apple's icon template expects the artwork to occupy ~80% of
            // a 1024×1024 canvas (824×824 with 100px transparent padding
            // on each side). Our Paper export fills the full canvas, so
            // it renders bigger than every other dock icon. Composite it
            // into a properly padded transparent canvas so the dock sees
            // it at the standard size.
            let canvasSide: CGFloat = 1024
            let artworkSide: CGFloat = 824
            let padding = (canvasSide - artworkSide) / 2
            let canvas = NSImage(size: NSSize(width: canvasSide, height: canvasSide))
            canvas.lockFocus()
            img.draw(
                in: NSRect(x: padding, y: padding, width: artworkSide, height: artworkSide),
                from: .zero,
                operation: .copy,
                fraction: 1.0
            )
            canvas.unlockFocus()
            NSApp.applicationIconImage = canvas
            FileHandle.standardError.write(Data(
                "[Icon] dock icon set from \(url.path) (rescaled to Apple template proportions)\n".utf8
            ))
        } else {
            FileHandle.standardError.write(Data(
                "[Icon] AppIcon.png not found in bundle — drop it at Sources/RefVault/Resources/icons/AppIcon.png\n".utf8
            ))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(
        _ sender: NSApplication
    ) -> Bool { true }

    /// Called from RefVaultApp.onAppear once the SwiftUI environment objects
    /// exist. We can't build this in didFinishLaunching because the SwiftUI
    /// state isn't reachable from there.
    func install<V: View>(island content: V) {
        guard statusItem == nil else { return }

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Custom menu-bar mark from Resources/icons. Try SVG first (vector,
        // scales cleanly across Retina + dark/light mode), then fall back
        // to PDF (also vector, more battle-tested as a template), then to
        // the SF Symbol if neither file is present yet — that keeps the
        // build runnable before the icon export lands.
        // isTemplate=true makes macOS auto-tint the glyph: white on a dark
        // menu bar, black on a light menu bar. The source SVG/PDF must be
        // monochrome black on transparent for templating to work right.
        let menuIcon: NSImage? = {
            for ext in ["svg", "pdf", "png"] {
                // Try subdirectory lookup first (most reliable with
                // SwiftPM's .copy rule), then a bare-name search that
                // walks the bundle recursively. Either path works once
                // the file is in place; covers both layouts in case the
                // bundle flattens differently across Xcode/CLI builds.
                let url = Bundle.module.url(
                    forResource: "MenuBarIcon",
                    withExtension: ext,
                    subdirectory: "Resources/icons"
                ) ?? Bundle.module.url(
                    forResource: "MenuBarIcon",
                    withExtension: ext
                )
                if let url, let img = NSImage(contentsOf: url) {
                    img.size = NSSize(width: 18, height: 18)
                    FileHandle.standardError.write(Data(
                        "[Icon] menu bar icon loaded from \(url.path)\n".utf8
                    ))
                    return img
                }
            }
            FileHandle.standardError.write(Data(
                "[Icon] no MenuBarIcon.{svg,pdf,png} found — falling back to SF Symbol photo.stack\n".utf8
            ))
            return NSImage(
                systemSymbolName: "photo.stack",
                accessibilityDescription: "RefVault"
            )
        }()
        menuIcon?.isTemplate = true
        item.button?.image = menuIcon
        item.button?.action = #selector(toggleIsland)
        item.button?.target = self
        statusItem = item

        let presenter = IslandPresenter()
        // Pin the popover to the screen the status item button actually
        // lives on. Without this it falls through to NSScreen.main, which
        // points at the screen with the key window — wrong target when
        // the user clicked the menu bar on a secondary display or while
        // a fullscreen app is active (no key window in the normal sense).
        presenter.screenResolver = { [weak item] in
            if let s = item?.button?.window?.screen { return s }
            let mouse = NSEvent.mouseLocation
            return NSScreen.screens.first(where: { $0.frame.contains(mouse) })
        }
        presenter.setContent(content)
        island = presenter

        if toast == nil { toast = ToastPresenter() }
        FileHandle.standardError.write(Data(
            "[Toast] install() ran — island=\(island != nil ? "ok" : "nil") toast=\(toast != nil ? "ok" : "nil")\n".utf8
        ))
    }

    @objc private func toggleIsland() {
        FileHandle.standardError.write(Data(
            "[Island] toggleIsland clicked — island=\(island != nil ? "ok" : "nil") isVisible=\(island?.isVisible ?? false) statusItem.button.window=\(statusItem?.button?.window != nil ? "ok" : "nil") buttonWindowScreen=\(statusItem?.button?.window?.screen.map { NSStringFromRect($0.frame) } ?? "nil") activeApp=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "nil")\n".utf8
        ))
        guard let island else { return }
        if island.isVisible {
            island.hide()
            removeDismissMonitor()
        } else {
            island.show()
            installDismissMonitor()
        }
    }

    private func installDismissMonitor() {
        globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.island?.hide()
                self?.removeDismissMonitor()
            }
        }
    }

    private func removeDismissMonitor() {
        if let m = globalDismissMonitor {
            NSEvent.removeMonitor(m)
            globalDismissMonitor = nil
        }
    }
}

@main
struct RefVaultApp: App {
    @NSApplicationDelegateAdaptor(RefVaultAppDelegate.self) var appDelegate

    @StateObject private var store: LibraryStore
    @StateObject private var watcher = ScreenshotWatcher()
    @StateObject private var coordinator: IngestionCoordinator
    @StateObject private var searchModel = SearchModel()

    init() {
        let store = LibraryStore()
        let agent = GemmaAgent(client: OllamaClient())
        let coordinator = IngestionCoordinator(store: store, agent: agent)
        _store = StateObject(wrappedValue: store)
        _coordinator = StateObject(wrappedValue: coordinator)
    }

    var body: some Scene {
        WindowGroup("RefVault") {
            MainWindow()
                .frame(minWidth: 960, minHeight: 600)
                .environmentObject(store)
                .environmentObject(coordinator)
                .environmentObject(watcher)
                .environmentObject(searchModel)
                .onAppear {
                    startWatching()
                    if searchModel.parser == nil {
                        // 26b only — no model swaps. Pinning a smaller
                        // model alongside (e2b/e4b) caused two problems:
                        // memory contention on the 24GB Mac (swap-thrash
                        // when both want keep_alive=-1) and cross-model
                        // weight juggling between every ingest and search
                        // call. Both go away when search rides the same
                        // warm 26b that ingestion uses.
                        searchModel.parser = SearchParser(
                            client: coordinator.agent.client,
                            vocabularyProvider: { [weak store] in
                                store?.vocabulary
                            }
                        )
                    }
                    // Pre-warm 26b so the user's first ingest / regen /
                    // search doesn't pay the ~55s cold-load.
                    Task.detached { [client = coordinator.agent.client] in
                        try? await client.preload()
                    }
                    // Backfill SHA + dHash for any records persisted
                    // before dedup landed. Without this, dropping the
                    // same image again wouldn't be detected as a dup
                    // because old records have nil hashes.
                    Task { [weak store] in
                        await store?.backfillHashesIfNeeded()
                    }
                    DispatchQueue.main.async {
                        NSApp.activate(ignoringOtherApps: true)
                        NSApp.windows.first?.makeKeyAndOrderFront(nil)
                    }
                    // Install must run BEFORE wiring onSaved so the
                    // diagnostic log accurately reports the toast presenter
                    // state and the closure has something to talk to from
                    // the very first save.
                    if appDelegate.island == nil {
                        // Capture the concrete delegate. Going through
                        // `NSApp.delegate as? RefVaultAppDelegate` was
                        // silently returning nil at click time — likely a
                        // SwiftUI `@NSApplicationDelegateAdaptor`
                        // proxy-wrapping detail. The captured reference
                        // bypasses the runtime cast entirely.
                        let delegateRef = appDelegate
                        let close: () -> Void = { [weak delegateRef] in
                            delegateRef?.island?.hide()
                        }
                        let content = MenuBarContent(onClose: close)
                            .environmentObject(store)
                            .environmentObject(coordinator)
                            .environmentObject(watcher)
                            .environmentObject(searchModel)
                        appDelegate.install(island: content)
                    }
                    // Wire AFTER install so the toast presenter exists at
                    // both wire-time and fire-time. Closure captures
                    // appDelegate / store / coordinator weakly so it stays
                    // safe across window lifecycle.
                    FileHandle.standardError.write(Data(
                        "[Toast] wiring coordinator.onSaved — toast presenter=\(appDelegate.toast != nil ? "exists" : "NIL")\n".utf8
                    ))
                    coordinator.onSaved = { [weak appDelegate, weak store, weak coordinator] saved, elapsed, kind in
                        guard let toast = appDelegate?.toast else {
                            FileHandle.standardError.write(Data(
                                "[Toast] onSaved fired but appDelegate.toast is nil — install never ran?\n".utf8
                            ))
                            return
                        }
                        let payload = ToastPayload(
                            thumbnailURL: store?.storedImageURL(for: saved),
                            style: saved.metadata?.style ?? saved.relevance.surface,
                            layout: saved.metadata?.layout ?? "",
                            tags: saved.metadata?.tags ?? [],
                            processingSeconds: elapsed,
                            queueCount: max(0, (coordinator?.totalInProgress ?? 1) - 1),
                            kind: kind == .regenerate ? .regenerate : .ingest
                        )
                        FileHandle.standardError.write(Data(
                            "[Toast] onSaved fired kind=\(kind == .regenerate ? "regenerate" : "ingest") → presenter.show\n".utf8
                        ))
                        toast.show(payload)
                    }
                    // Duplicate skip — surface the existing record so the
                    // user gets feedback that their drop wasn't lost.
                    coordinator.onDuplicate = { [weak appDelegate, weak store, weak coordinator] newURL, matches, reason in
                        guard let toast = appDelegate?.toast else { return }
                        let hamming: Int?
                        switch reason {
                        case .exact: hamming = nil
                        case .visual(let h): hamming = h
                        }
                        // Resolve each match's stored image URL up front so
                        // the toast view doesn't need to reach into the
                        // store at render time.
                        let matchURLs: [URL] = matches.compactMap { rec in
                            store?.storedImageURL(for: rec)
                        }
                        let saveAnyway: () -> Void = { [weak coordinator] in
                            coordinator?.enqueueBypassingDedup(newURL)
                        }
                        let payload = ToastPayload(
                            thumbnailURL: matchURLs.first,
                            style: matches.first?.metadata?.style
                                ?? matches.first?.relevance.surface ?? "",
                            layout: matches.first?.metadata?.layout ?? "",
                            tags: matches.first?.metadata?.tags ?? [],
                            processingSeconds: nil,
                            queueCount: max(0, (coordinator?.totalInProgress ?? 0)),
                            kind: .duplicate(
                                newImageURL: newURL,
                                matches: matchURLs,
                                hamming: hamming,
                                onSaveAnyway: saveAnyway
                            )
                        )
                        FileHandle.standardError.write(Data(
                            "[Toast] onDuplicate fired reason=\(hamming.map { "visual h=\($0)" } ?? "exact") matches=\(matches.count) → presenter.show\n".utf8
                        ))
                        toast.show(payload)
                    }
                }
        }
    }

    private func startWatching() {
        watcher.onNewImage = { [weak coordinator] url in
            coordinator?.enqueue(url)
        }
        if !watcher.isActive {
            watcher.start(folders: ScreenshotWatcher.defaultFolders)
        }
    }
}
