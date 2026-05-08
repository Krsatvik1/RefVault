import SwiftUI

@main
struct RefVaultApp: App {
    @StateObject private var store = LibraryStore()
    @StateObject private var watcher = ScreenshotWatcher()
    @StateObject private var coordinator: IngestionCoordinator

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
                .onAppear { startWatching() }
        }
        .windowResizability(.contentSize)
    }

    private func startWatching() {
        // Wire watcher → coordinator on first appearance.
        watcher.onNewImage = { [weak coordinator] url in
            coordinator?.enqueue(url)
        }
        if !watcher.isActive {
            watcher.start(folders: ScreenshotWatcher.defaultFolders)
        }
    }
}
