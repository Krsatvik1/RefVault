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
    private var globalDismissMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
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
        let img = NSImage(
            systemSymbolName: "photo.stack",
            accessibilityDescription: "RefVault"
        )
        img?.isTemplate = true
        item.button?.image = img
        item.button?.action = #selector(toggleIsland)
        item.button?.target = self
        statusItem = item

        let presenter = IslandPresenter()
        presenter.setContent(content)
        island = presenter
    }

    @objc private func toggleIsland() {
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
                        // Search-query parsing is short-prompt JSON-mode
                        // work; e4b is fast (~1-2s vs 5-8s on the 26b
                        // primary) and accurate enough when the library
                        // vocabulary is fed in via vocabularyProvider.
                        searchModel.parser = SearchParser(
                            client: coordinator.agent.client.withModel("gemma4:e4b"),
                            vocabularyProvider: { [weak store] in
                                store?.vocabulary
                            }
                        )
                    }
                    // Pre-warm Ollama so the user's first ingest / regen
                    // doesn't pay the ~55s cold-load on the relevance call.
                    // Fire-and-forget — if Ollama is down, the next real
                    // call will surface the error.
                    Task.detached { [client = coordinator.agent.client] in
                        try? await client.preload()
                    }
                    DispatchQueue.main.async {
                        NSApp.activate(ignoringOtherApps: true)
                        NSApp.windows.first?.makeKeyAndOrderFront(nil)
                    }
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
