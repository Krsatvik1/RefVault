import Foundation

/// Watches one or more folders for new image files and emits URLs to a
/// callback. Uses DispatchSource on each folder's file descriptor with a
/// 500ms debounce — macOS often fires write+close as two events for one
/// new file.
@MainActor
final class ScreenshotWatcher: ObservableObject {
    @Published private(set) var watchedFolders: [URL] = []
    @Published private(set) var isActive: Bool = false

    var onNewImage: ((URL) -> Void)?

    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    private var fds: [URL: Int32] = [:]
    private var lastSnapshot: [URL: Set<URL>] = [:]
    private var debounceWorkItems: [URL: DispatchWorkItem] = [:]
    private let queue = DispatchQueue(label: "RefVault.watcher", qos: .utility)
    private let allowedExt: Set<String> = ["png", "jpg", "jpeg", "heic", "webp"]

    /// Default Mac screenshot locations.
    static var defaultFolders: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Pictures/Screenshots", isDirectory: true)
        ].filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func start(folders: [URL]) {
        stop()
        watchedFolders = folders
        for folder in folders {
            startWatching(folder)
        }
        isActive = !sources.isEmpty
    }

    func stop() {
        for (_, src) in sources { src.cancel() }
        sources.removeAll()
        for (_, fd) in fds { close(fd) }
        fds.removeAll()
        debounceWorkItems.values.forEach { $0.cancel() }
        debounceWorkItems.removeAll()
        isActive = false
    }

    /// Force a rescan of every watched folder. Useful for a "Scan now" button.
    func scanNow() {
        for folder in watchedFolders {
            handleFolderEvent(folder)
        }
    }

    /// Emits every existing image in the watched folders that the caller
    /// has not yet seen. Use sparingly — kicks off ingestion for every file.
    func emitExistingFiles() {
        for folder in watchedFolders {
            let urls = currentImageURLs(in: folder)
            lastSnapshot[folder] = urls
            for url in urls.sorted(by: { $0.path < $1.path }) {
                onNewImage?(url)
            }
        }
    }

    // MARK: - Internals

    private func startWatching(_ folder: URL) {
        let fd = open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.scheduleDebounce(folder) }
        }
        source.setCancelHandler { close(fd) }
        sources[folder] = source
        fds[folder] = fd
        // Seed the snapshot so existing files are not re-emitted as "new"
        // on launch. Use emitExistingFiles() if you actually want them.
        lastSnapshot[folder] = currentImageURLs(in: folder)
        source.resume()
    }

    private func scheduleDebounce(_ folder: URL) {
        debounceWorkItems[folder]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.handleFolderEvent(folder) }
        }
        debounceWorkItems[folder] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500), execute: item)
    }

    private func handleFolderEvent(_ folder: URL) {
        let now = currentImageURLs(in: folder)
        let prev = lastSnapshot[folder] ?? []
        let added = now.subtracting(prev)
        lastSnapshot[folder] = now
        for url in added.sorted(by: { $0.path < $1.path }) {
            onNewImage?(url)
        }
    }

    private func currentImageURLs(in folder: URL) -> Set<URL> {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return Set(contents.filter {
            allowedExt.contains($0.pathExtension.lowercased())
        })
    }
}
