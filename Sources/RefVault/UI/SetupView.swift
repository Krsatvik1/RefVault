import SwiftUI

/// First-run / cold-boot UI. Renders while:
///   - the bundled `ollama serve` is starting up (usually invisible — a
///     few hundred ms), or
///   - the 26B model is downloading on a fresh install (15+ GB, slow), or
///   - bootstrap has hit a terminal error and the user needs to retry.
///
/// On a warm machine where the model is already pulled, this view flashes
/// for ~200ms before MainWindow takes over.
struct SetupView: View {
    @ObservedObject var bootstrap: AppBootstrap

    var body: some View {
        ZStack {
            // Plain neutral background — matches the eventual MainWindow
            // chrome so the transition isn't a jarring color flip.
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea()

            VStack(spacing: 18) {
                Spacer()
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.primary.opacity(0.85))

                Text("RefVault")
                    .font(.system(size: 22, weight: .semibold))

                Group {
                    switch bootstrap.phase {
                    case .startingDaemon:
                        startingDaemon
                    case .checkingModel:
                        checkingModel
                    case .downloadingModel(let p):
                        downloadingModel(p)
                    case .failed(let reason):
                        failed(reason)
                    case .ready:
                        // Should never render — RefVaultApp gates the
                        // view tree on .ready. If we somehow do, render
                        // a benign placeholder rather than crash.
                        EmptyView()
                    }
                }
                .frame(maxWidth: 420)
                Spacer()
            }
            .padding(40)
        }
        .frame(minWidth: 560, minHeight: 380)
    }

    // MARK: - Phase views

    private var startingDaemon: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Starting local model runtime…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var checkingModel: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Checking for Gemma 4 26B…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private func downloadingModel(_ p: ModelDownloader.Progress) -> some View {
        VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text("Downloading Gemma 4 26B")
                    .font(.system(size: 14, weight: .medium))
                Text("This is a one-time ~15 GB download. The app will start automatically when it finishes.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Indeterminate while we don't yet know the total size; fills
            // in as soon as the daemon reports the first layer total.
            if let frac = p.fraction {
                ProgressView(value: frac)
                    .progressViewStyle(.linear)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
            }

            HStack {
                Text(p.status)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(byteSummary(completed: p.completedBytes, total: p.totalBytes))
                    .monospacedDigit()
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private func failed(_ reason: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 28))
            Text("Couldn't get the model running")
                .font(.system(size: 14, weight: .medium))
            Text(reason)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Button("Retry") { bootstrap.start() }
                .controlSize(.large)
                .padding(.top, 6)
        }
    }

    // MARK: - Formatting

    private func byteSummary(completed: Int64, total: Int64) -> String {
        if total <= 0 {
            return formatBytes(completed)
        }
        return "\(formatBytes(completed)) / \(formatBytes(total))"
    }

    private func formatBytes(_ n: Int64) -> String {
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useGB, .useMB]
        bcf.countStyle = .file
        return bcf.string(fromByteCount: n)
    }
}
