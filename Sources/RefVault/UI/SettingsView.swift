import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var watcher: ScreenshotWatcher
    @EnvironmentObject var coordinator: IngestionCoordinator

    @State private var availableModels: [String] = OllamaClient.knownGemmaModels

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Settings")
                    .font(.title2.weight(.semibold))

                section("Watching") {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(watcher.isActive ? "Active" : "Inactive")
                                .font(.callout.weight(.medium))
                            Text(watcher.watchedFolders.isEmpty
                                ? "No folders configured."
                                : watcher.watchedFolders.map(\.path).joined(separator: "\n"))
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        if watcher.isActive {
                            Button("Stop") { watcher.stop() }
                        } else {
                            Button("Start") {
                                watcher.start(folders: ScreenshotWatcher.defaultFolders)
                            }
                        }
                    }
                    HStack {
                        Button("Add folder…") { pickFolder() }
                        Button("Reset to defaults") {
                            watcher.start(folders: ScreenshotWatcher.defaultFolders)
                        }
                    }
                }

                section("Primary model") {
                    HStack {
                        Picker("", selection: $coordinator.primaryModel) {
                            ForEach(availableModels, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 280)
                        Spacer()
                    }
                    Text("Used for auto-ingest and the Detail view's Regenerate button. The Debug tab can pick a different model per slot.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                section("Extraction strategy") {
                    Toggle(isOn: $coordinator.granularExtraction) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Granular metadata")
                                .font(.callout.weight(.medium))
                            Text("Split metadata into 5 per-field calls (style, typography, layout, mood, tags). Slower but materially better with smaller models like gemma4:e4b.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Toggle(isOn: $coordinator.serialExecution) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Serial execution")
                                .font(.callout.weight(.medium))
                            Text("Run one Ollama call at a time. Recommended on — parallel calls fight for the same KV cache and rarely speed things up on M-series Macs.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Toggle(isOn: $coordinator.urlFirstFlow) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("URL-first + chrome crop")
                                .font(.callout.weight(.medium))
                            Text("Run URL extraction before everything else; if a URL is found, crop the top 12% of the image (browser chrome) before metadata + palette + relevance. Off by default — uses the original parallel flow with no cropping.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    Text("These settings apply to auto-ingest, Regenerate, and the default of new Debug slots — for both gemma4:26b and gemma4:e4b.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.top, 4)
                }

                section("Confidence threshold") {
                    HStack {
                        Slider(value: $store.confidenceThreshold, in: 0...1, step: 0.05)
                        Text(String(format: "%.2f", store.confidenceThreshold))
                            .font(.body.monospaced())
                            .frame(width: 48, alignment: .trailing)
                    }
                    Text("Screenshots are saved only if Gemma rates them as a design reference with confidence ≥ this value. Higher = stricter; fewer false positives but more rejections.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                section("Library") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(store.records.count) saved")
                                .font(.callout.weight(.medium))
                            Text(store.libraryDirectory.path)
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([store.libraryDirectory])
                        }
                    }
                }

                if !coordinator.recentLog.isEmpty {
                    section("Recent activity") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(coordinator.recentLog.prefix(20)) { line in
                                HStack(alignment: .top, spacing: 8) {
                                    Circle()
                                        .fill(line.saved ? Color.green : Color.orange)
                                        .frame(width: 6, height: 6)
                                        .padding(.top, 6)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(line.url.lastPathComponent)
                                            .font(.caption.monospaced())
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Text(line.outcome)
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                if let err = store.lastError {
                    Text(err)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .task { await refreshModels() }
    }

    private func refreshModels() async {
        do {
            let installed = try await coordinator.agent.client.listModels()
            let gemmas = installed.filter { $0.hasPrefix("gemma4") }
            let merged = Array(Set(gemmas + OllamaClient.knownGemmaModels)).sorted()
            await MainActor.run { availableModels = merged }
        } catch {
            // keep static list on failure
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            var folders = watcher.watchedFolders
            if !folders.contains(url) { folders.append(url) }
            watcher.start(folders: folders)
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
                .tracking(0.5)
            content()
        }
        .padding(16)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(10)
    }
}
