import Foundation

/// Spawns and supervises a private `ollama serve` instance.
///
/// Why a private instance instead of riding whatever Ollama the user has
/// installed:
///   - We need the .app to work on a machine that has never had Ollama
///     installed (the "fresh designer Mac" cold-install case).
///   - Sharing a port with a system Ollama causes silent contention: the
///     two daemons race to bind 11434 and only the first one wins. The
///     loser's API calls 404 against the wrong server.
///   - The bundled instance keeps its weights in a separate models dir,
///     so uninstalling RefVault doesn't strand 15GB of Gemma weights in
///     the user's `~/.ollama/models` and (more importantly) doesn't
///     blow away the user's own Ollama models when we clean up.
///
/// Resolution order for the binary:
///   1. `Bundle.main.resourceURL/ollama` — production .app layout
///   2. `<repo-root>/Vendored/ollama/ollama` — dev mode, after running
///      `scripts/fetch-ollama.sh` once
///   3. system paths (`/opt/homebrew/bin/ollama`, `/usr/local/bin/ollama`,
///      `/Applications/Ollama.app/Contents/Resources/ollama`) — fallback
///      so a developer who already has Ollama can run the app from
///      `swift run` without going through fetch-ollama.sh first
@MainActor
final class OllamaSupervisor: ObservableObject {
    /// Public state machine. SwiftUI views (SetupView) bind to this.
    enum State: Equatable {
        /// Nothing running. Initial state.
        case idle
        /// `ollama serve` spawned, waiting for /api/tags to respond.
        case starting
        /// Daemon is up and answering on `baseURL`.
        case ready
        /// Couldn't find the binary, port was taken, daemon crashed, etc.
        case failed(reason: String)
    }

    @Published private(set) var state: State = .idle

    /// URL clients should use once `state == .ready`. Stable across the
    /// supervisor's lifetime — we always bind the same port.
    let baseURL: URL

    /// Where Ollama writes downloaded model weights. Separate from the
    /// user's `~/.ollama/models` so we own the lifecycle.
    let modelsDir: URL

    /// Resolved path to the `ollama` binary. Set after `start()` finds it.
    private(set) var resolvedBinaryPath: String?

    /// Path to the supervised log file. Tail this if the daemon misbehaves.
    let logURL: URL

    private var process: Process?
    private var logHandle: FileHandle?
    /// Polls /api/tags until the daemon answers. Cancelled in `stop()`.
    private var readinessTask: Task<Void, Never>?
    /// Watches `process.terminationHandler` so we can flip `state` to
    /// `.failed` if the daemon dies after reaching .ready.
    private var crashObserver: NSObjectProtocol?

    /// Bound port for the supervised daemon. High number to stay clear of
    /// the default 11434 the user's system Ollama listens on. Fixed (not
    /// dynamically allocated) so the URL is stable across launches and so
    /// the user can curl it for debugging.
    nonisolated static let port: Int = 11535

    /// Init is `nonisolated` because SwiftUI's `App.init` runs outside any
    /// actor context and we want the supervisor to be constructible from
    /// there. We only assign `let` properties here — no isolated state is
    /// touched, so this is safe under strict concurrency.
    nonisolated init() {
        let support = OllamaSupervisor.applicationSupportDir()
        self.modelsDir = support.appendingPathComponent("models", isDirectory: true)
        self.logURL = support.appendingPathComponent("ollama.log")
        self.baseURL = URL(string: "http://127.0.0.1:\(OllamaSupervisor.port)")!
    }

    /// Spawn `ollama serve`. Returns immediately; readiness is observable
    /// via `state`. Safe to call multiple times — re-entry is a no-op
    /// while a process is running.
    func start() {
        guard process == nil else {
            log("start() ignored — already running pid=\(process?.processIdentifier ?? -1)")
            return
        }
        state = .starting

        guard let binary = resolveBinary() else {
            state = .failed(reason: "ollama binary not found in bundle, vendored, or system paths")
            return
        }
        resolvedBinaryPath = binary
        log("resolved ollama binary: \(binary)")

        do {
            try FileManager.default.createDirectory(
                at: modelsDir, withIntermediateDirectories: true
            )
        } catch {
            state = .failed(reason: "could not create models dir: \(error.localizedDescription)")
            return
        }

        // Touch the log file and open a write handle. Streaming the
        // child's stderr/stdout into here is invaluable when debugging
        // pull failures or model load issues — the on-screen progress
        // bar only shows the structured pull events, not the raw daemon
        // chatter that explains *why* a pull stalled.
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        logHandle = try? FileHandle(forWritingTo: logURL)
        logHandle?.seekToEndOfFile()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["serve"]
        var env = ProcessInfo.processInfo.environment
        env["OLLAMA_HOST"] = "127.0.0.1:\(Self.port)"
        env["OLLAMA_MODELS"] = modelsDir.path
        // Origin lockdown isn't strictly needed (we only call from the
        // app process) but Ollama defaults to localhost-only anyway and
        // setting OLLAMA_ORIGINS to nothing keeps cross-origin browser
        // requests from probing the daemon.
        env["OLLAMA_ORIGINS"] = "http://127.0.0.1:\(Self.port)"
        proc.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        // Forward both streams into the supervised log file. Async — the
        // handler is called as the kernel hands us new bytes.
        let writeToLog: (FileHandle) -> Void = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.logHandle?.write(data)
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = writeToLog
        stderrPipe.fileHandleForReading.readabilityHandler = writeToLog

        proc.terminationHandler = { [weak self] terminated in
            // Hop to main — termination handler runs on a background queue.
            Task { @MainActor [weak self] in
                guard let self else { return }
                let code = terminated.terminationStatus
                self.log("ollama serve exited code=\(code)")
                // Only flip to .failed if we hadn't been asked to stop
                // (process is still our own). On a clean stop() we null
                // out `self.process` first, then send terminate, so this
                // branch sees `self.process == nil` and stays quiet.
                if self.process === terminated {
                    self.process = nil
                    if case .ready = self.state {
                        self.state = .failed(reason: "ollama serve exited unexpectedly (code \(code))")
                    } else if case .starting = self.state {
                        self.state = .failed(reason: "ollama serve exited before becoming ready (code \(code))")
                    }
                }
            }
        }

        do {
            try proc.run()
            self.process = proc
            log("spawned ollama serve pid=\(proc.processIdentifier) host=127.0.0.1:\(Self.port) models=\(modelsDir.path)")
        } catch {
            state = .failed(reason: "failed to spawn ollama: \(error.localizedDescription)")
            return
        }

        readinessTask = Task { [weak self] in
            await self?.waitUntilReachable()
        }
    }

    /// Kill the supervised daemon. Idempotent — safe to call from
    /// `applicationWillTerminate` even if `start()` was never called.
    func stop() {
        readinessTask?.cancel()
        readinessTask = nil
        guard let proc = process else { return }
        process = nil
        log("terminating ollama serve pid=\(proc.processIdentifier)")
        proc.terminate()
        // Give it 2s to drain a graceful shutdown, then SIGKILL. Ollama's
        // /api/generate with keep_alive=-1 holds the model in VRAM and
        // graceful shutdown frees that cleanly; SIGKILL leaves orphan
        // mmap'd model files until the kernel reaps them.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
        }
        logHandle?.closeFile()
        logHandle = nil
        state = .idle
    }

    // MARK: - Internals

    private func waitUntilReachable() async {
        let pollURL = baseURL.appendingPathComponent("api/tags")
        // Generous total budget — first launch on a slow disk can take
        // a few seconds for the daemon to come up. We poll cheaply
        // (every 250ms) so the user sees the transition fast when it's
        // actually fast.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if Task.isCancelled { return }
            do {
                var req = URLRequest(url: pollURL)
                req.timeoutInterval = 1.0
                let (_, response) = try await URLSession.shared.data(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    self.log("daemon answering on \(self.baseURL.absoluteString)")
                    self.state = .ready
                    return
                }
            } catch {
                // Connection refused / not yet bound — expected during
                // startup. Swallow and keep polling.
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if !Task.isCancelled {
            self.state = .failed(reason: "ollama daemon did not respond within 30s")
        }
    }

    private func resolveBinary() -> String? {
        // 1. Production: bundled inside the .app's Resources dir.
        if let resourceURL = Bundle.main.resourceURL {
            let candidate = resourceURL.appendingPathComponent("ollama").path
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        // 2. Dev mode: walk up from the executable to find Vendored/ollama/ollama.
        // `swift run` puts the binary at .build/<arch>-apple-macosx/release/RefVault.
        // From there walk up until we find Package.swift, then look for Vendored/.
        var dir = Bundle.main.bundleURL
        for _ in 0..<6 {
            let pkg = dir.appendingPathComponent("Package.swift").path
            if FileManager.default.fileExists(atPath: pkg) {
                let vendored = dir.appendingPathComponent("Vendored/ollama/ollama").path
                if FileManager.default.isExecutableFile(atPath: vendored) {
                    return vendored
                }
                break
            }
            dir = dir.deletingLastPathComponent()
        }

        // 3. System fallbacks. /opt/homebrew is Apple Silicon Homebrew;
        // /usr/local is Intel Homebrew; the .app path is what Ollama's
        // own desktop installer drops.
        let systemPaths = [
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama"
        ]
        return systemPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    nonisolated private static func applicationSupportDir() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("RefVault", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func log(_ msg: String) {
        FileHandle.standardError.write(Data("[Supervisor] \(msg)\n".utf8))
    }
}
