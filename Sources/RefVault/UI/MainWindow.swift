import SwiftUI

enum NavSection: String, Hashable, CaseIterable, Identifiable {
    case library, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .library: return "Library"
        case .settings: return "Settings"
        }
    }
    var systemImage: String {
        switch self {
        case .library: return "square.grid.2x2"
        case .settings: return "gear"
        }
    }
}

struct MainWindow: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var coordinator: IngestionCoordinator
    @EnvironmentObject var watcher: ScreenshotWatcher
    @EnvironmentObject var searchModel: SearchModel

    @State private var selection: NavSection = .library
    @State private var modelStatus: String = "Checking Ollama…"

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section("Browse") {
                    Label(NavSection.library.title, systemImage: NavSection.library.systemImage)
                        .tag(NavSection.library)
                }
                Section("App") {
                    Label(NavSection.settings.title, systemImage: NavSection.settings.systemImage)
                        .tag(NavSection.settings)
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .safeAreaInset(edge: .bottom) {
                StatusFooter(modelStatus: modelStatus)
            }
        } detail: {
            switch selection {
            case .library:
                LibraryView()
            case .settings:
                SettingsView()
            }
        }
        // Search lives inside LibraryView's header now — we get full
        // styling control there instead of fighting with the toolbar's
        // imposed text-field look + system-blue focus ring.
        .task { await checkOllama() }
    }

    private func checkOllama() async {
        let client = coordinator.agent.client
        do {
            let models = try await client.listModels()
            let gemma4 = models.filter { $0.hasPrefix("gemma4") }
            if gemma4.contains(client.model) {
                modelStatus = "Ollama OK · \(client.model)"
            } else if !gemma4.isEmpty {
                modelStatus = "Ollama OK · default \(client.model) not pulled (have: \(gemma4.joined(separator: ", ")))"
            } else if models.isEmpty {
                modelStatus = "Ollama OK · no models"
            } else {
                modelStatus = "Ollama OK · gemma4 not pulled"
            }
        } catch {
            modelStatus = "Ollama unreachable"
        }
    }
}

private struct StatusFooter: View {
    let modelStatus: String
    @EnvironmentObject var watcher: ScreenshotWatcher
    @EnvironmentObject var coordinator: IngestionCoordinator
    @EnvironmentObject var store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(watcher.isActive ? Color.green : Color.gray)
                    .frame(width: 7, height: 7)
                Text(watcher.isActive
                    ? "Watching \(watcher.watchedFolders.count) folder\(watcher.watchedFolders.count == 1 ? "" : "s")"
                    : "Watcher off"
                )
                .font(.caption)
                .foregroundColor(.secondary)
            }
            Text(modelStatus)
                .font(.caption2)
                .foregroundColor(.secondary)
            if let inFlight = coordinator.inFlight {
                Text("Indexing \(inFlight.lastPathComponent)…")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if coordinator.queueDepth > 0 {
                Text("\(coordinator.queueDepth) queued")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.secondary.opacity(0.07))
    }
}
