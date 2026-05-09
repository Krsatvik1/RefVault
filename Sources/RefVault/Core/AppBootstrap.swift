import Foundation
import Combine

/// Top-level bootstrap state for the app.
///
/// RefVaultApp's body switches on this enum so the user sees a real
/// progress UI for the two slow first-launch steps (start the bundled
/// Ollama daemon, pull the 26B model on cold install) instead of a
/// blank window or — worse — the main UI with every Gemma call timing
/// out for 8 minutes.
@MainActor
final class AppBootstrap: ObservableObject {
    enum Phase: Equatable {
        /// Supervisor is spawning `ollama serve` and waiting for it to
        /// answer. Usually <2s.
        case startingDaemon
        /// Daemon is up; we're calling /api/tags to see if the model is
        /// already pulled. Usually <100ms.
        case checkingModel
        /// Model isn't on disk; running /api/pull. The slowest phase —
        /// 15GB on a residential connection is 20–60 minutes.
        case downloadingModel(ModelDownloader.Progress)
        /// Everything is up. MainWindow renders.
        case ready
        /// Terminal error. Render an error view with a retry button that
        /// calls `start()` again.
        case failed(String)
    }

    @Published private(set) var phase: Phase = .startingDaemon

    let supervisor: OllamaSupervisor
    let modelTag: String

    private var supervisorObserver: AnyCancellable?
    private var pullTask: Task<Void, Never>?

    /// Init is `nonisolated` so SwiftUI's `App.init` (which is not main-
    /// actor isolated) can construct it. No isolated state is touched in
    /// the body — only stored-property assignment.
    nonisolated init(
        supervisor: OllamaSupervisor = OllamaSupervisor(),
        modelTag: String = OllamaClient.defaultModel
    ) {
        self.supervisor = supervisor
        self.modelTag = modelTag
    }

    /// Kick off the daemon + readiness check. Idempotent — calling again
    /// from a "Retry" button works because supervisor.start() is itself
    /// idempotent and we re-subscribe cleanly.
    func start() {
        phase = .startingDaemon
        supervisorObserver = supervisor.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                self?.handleSupervisorState(state)
            }
        supervisor.start()
    }

    /// Tear down on app quit. Cancels the pull stream cleanly and stops
    /// the daemon so we don't leak a 26B model pinned in VRAM.
    func shutdown() {
        pullTask?.cancel()
        pullTask = nil
        supervisorObserver = nil
        supervisor.stop()
    }

    /// Force a re-check of /api/tags. Used after the user's first manual
    /// pull (hypothetically — currently we drive the pull ourselves), or
    /// on a Retry click after a transient daemon failure.
    func recheck() {
        guard supervisor.state == .ready else { return }
        Task { await self.checkModel() }
    }

    // MARK: - Internals

    private func handleSupervisorState(_ state: OllamaSupervisor.State) {
        switch state {
        case .idle, .starting:
            // Stay in startingDaemon — supervisor is mid-spawn.
            if case .failed = phase { return }
            phase = .startingDaemon
        case .ready:
            phase = .checkingModel
            Task { await self.checkModel() }
        case .failed(let reason):
            phase = .failed("Ollama daemon: \(reason)")
        }
    }

    private func checkModel() async {
        let client = OllamaClient(baseURL: supervisor.baseURL)
        do {
            let tags = try await client.listModels()
            // Ollama tag form is `name:variant` — match the full ref to
            // avoid false positives like "gemma:7b" matching "gemma4:26b".
            if tags.contains(modelTag) {
                phase = .ready
                return
            }
            beginPull()
        } catch {
            phase = .failed("could not list models: \(error.localizedDescription)")
        }
    }

    private func beginPull() {
        phase = .downloadingModel(.starting)
        let downloader = ModelDownloader(baseURL: supervisor.baseURL)
        let tag = modelTag
        pullTask = Task { [weak self] in
            do {
                try await downloader.pull(model: tag) { progress in
                    self?.phase = .downloadingModel(progress)
                }
                if Task.isCancelled { return }
                self?.phase = .ready
            } catch {
                if Task.isCancelled { return }
                self?.phase = .failed("model download: \(error.localizedDescription)")
            }
        }
    }
}
