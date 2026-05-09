import SwiftUI
import AppKit

/// Content for the notch-anchored island. The visual model is a stylized
/// macOS menu-bar wing on top (status light + wordmark + control icons + live
/// indexing pill), with a search-led panel below (search field, filter chips,
/// horizontal-scroll result rail, scroll position track).
struct MenuBarContent: View {
    @EnvironmentObject var store: LibraryStore
    @EnvironmentObject var coordinator: IngestionCoordinator
    @EnvironmentObject var watcher: ScreenshotWatcher
    @EnvironmentObject var searchModel: SearchModel

    /// Invoked by the explicit close button. Wired up by RefVaultApp to call
    /// `IslandPresenter.hide()`.
    var onClose: () -> Void = {}

    @State private var revealed = false
    @State private var spinAngle: Double = 0

    private let rosePrimary = Color(red: 1.0, green: 0.216, blue: 0.373)
    private let rosePale = Color(red: 1.0, green: 0.553, blue: 0.659)

    private var indexingCount: Int {
        coordinator.totalInProgress
    }

    private var filteredRecords: [ScreenshotRecord] {
        if let f = searchModel.parsedFilter, !f.isEmpty {
            return store.search(filter: f)
        }
        return store.records
    }

    private var hasActiveFilters: Bool {
        if let f = searchModel.parsedFilter, !f.isEmpty { return true }
        return false
    }

    var body: some View {
        ZStack(alignment: .top) {
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 28,
                bottomTrailingRadius: 28,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(Color.black)
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: 28,
                    bottomTrailingRadius: 28,
                    topTrailingRadius: 0,
                    style: .continuous
                )
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.45), radius: 22, y: 10)

            VStack(spacing: 12) {
                menuBarStrip
                searchField
                filterRow
                resultRail
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.top, 6)
            .padding(.bottom, 14)
            .opacity(revealed ? 1 : 0)
            .animation(.easeOut(duration: 0.25), value: revealed)
        }
        .preferredColorScheme(.dark)
        .onAppear {
            revealed = false
            spinAngle = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
                    revealed = true
                }
            }
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                spinAngle = 360
            }
        }
        .onDisappear { revealed = false }
    }

    // MARK: - Menu bar strip

    private var menuBarStrip: some View {
        HStack(spacing: 8) {
            statusLight
            Text("RefVault")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1, height: 14)
                .padding(.horizontal, 4)

            controlIcon(
                system: watcher.isActive ? "pause.fill" : "play.fill",
                help: watcher.isActive ? "Pause watching" : "Resume watching"
            ) {
                if watcher.isActive {
                    watcher.stop()
                } else {
                    watcher.start(folders: ScreenshotWatcher.defaultFolders)
                }
            }
            controlIcon(system: "arrow.clockwise", help: "Scan now") {
                watcher.scanNow()
            }
            controlIcon(system: "folder", help: "Open watched folder") {
                openWatchedFolder()
            }
            controlIcon(system: "viewfinder", help: "Re-scan all") {
                watcher.scanNow()
            }
            controlIcon(system: "gearshape", help: "Settings") {
                openMainWindow()
            }

            Spacer(minLength: 8)

            if indexingCount > 0 {
                indexingPill
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(store.records.count)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Text("REFS")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
                    .tracking(1)
            }

            Button(action: openMainWindow) {
                HStack(spacing: 4) {
                    Image(systemName: "rectangle.stack.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Library")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundColor(.black)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain)
            .help("Open library window")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(Color.white.opacity(0.06)))
                    .overlay(Circle().stroke(Color.white.opacity(0.06), lineWidth: 0.5))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .frame(height: 30)
    }

    private var statusLight: some View {
        ZStack {
            Circle()
                .fill(watcher.isActive ? Color(red: 0.20, green: 0.78, blue: 0.35) : Color.gray)
                .frame(width: 9, height: 9)
            if watcher.isActive {
                Circle()
                    .stroke(Color(red: 0.20, green: 0.78, blue: 0.35).opacity(0.5), lineWidth: 0.5)
                    .frame(width: 15, height: 15)
            }
        }
        .frame(width: 16, height: 16)
    }

    @ViewBuilder
    private func controlIcon(
        system: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var indexingPill: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(rosePale)
                .rotationEffect(.degrees(spinAngle))
            Text("\(indexingCount)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundColor(rosePale)
            if let started = coordinator.inFlightStartedAt {
                TimelineView(.periodic(from: started, by: 0.1)) { ctx in
                    Text(formatElapsed(ctx.date.timeIntervalSince(started)))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(rosePale.opacity(0.85))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(rosePrimary.opacity(0.14)))
        .overlay(Capsule().stroke(rosePrimary.opacity(0.35), lineWidth: 0.5))
    }

    private func formatElapsed(_ s: TimeInterval) -> String {
        if s < 60 { return String(format: "+%.1fs", s) }
        let m = Int(s) / 60
        let r = s - Double(m * 60)
        return String(format: "+%dm%.0fs", m, r)
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            TextField("Search references…", text: $searchModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .onChange(of: searchModel.query) { newValue in
                    searchModel.schedule(newValue)
                }
                .onSubmit {
                    searchModel.submit()
                }

            if searchModel.isParsing {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.7))
            } else if !searchModel.query.isEmpty {
                Text("\(filteredRecords.count) matches")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))

                Button(action: { searchModel.clear() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help("Clear search")
            }

            Text("⌘K")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.65))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.08)))
        }
        .frame(height: 32)
        .padding(.horizontal, 14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color.white.opacity(0.10), lineWidth: 0.5))
    }

    // MARK: - Filter row

    private struct ChipModel: Identifiable {
        let id = UUID()
        let label: String
        let value: String
        let count: Int
        let isPrimary: Bool
        let leading: Leading
        let onRemove: () -> Void

        enum Leading {
            case none
            case typeAa
            case colors([Color])
        }
    }

    private var activeChips: [ChipModel] {
        guard let f = searchModel.parsedFilter else { return [] }
        var chips: [ChipModel] = []

        if let styles = f.styles, let v = styles.first {
            let count = filteredRecords.filter {
                ($0.metadata?.style.lowercased() ?? "").contains(v.lowercased())
            }.count
            chips.append(ChipModel(
                label: "STYLE", value: v, count: count,
                isPrimary: true, leading: .none,
                onRemove: { /* no granular axis remove yet */ searchModel.clear() }
            ))
        }
        if let surfaces = f.surfaces, let v = surfaces.first {
            let count = filteredRecords.filter { $0.relevance.surface.lowercased() == v.lowercased() }.count
            chips.append(ChipModel(
                label: "SURFACE", value: v, count: count,
                isPrimary: false, leading: .none,
                onRemove: { searchModel.clear() }
            ))
        }
        if let any = f.tagsAny, let v = any.first {
            chips.append(ChipModel(
                label: "TYPE", value: v, count: filteredRecords.count,
                isPrimary: false, leading: .typeAa,
                onRemove: { searchModel.clear() }
            ))
        }
        if let colors = f.colors, !colors.isEmpty {
            let swatches = Array(colors.prefix(3)).compactMap { Color.named(swatch: $0) }
            chips.append(ChipModel(
                label: "COLOR", value: colors.first ?? "", count: filteredRecords.count,
                isPrimary: false, leading: .colors(swatches),
                onRemove: { searchModel.clear() }
            ))
        }
        if let moods = f.moods, let v = moods.first {
            let count = filteredRecords.filter {
                ($0.metadata?.mood.lowercased() ?? "").contains(v.lowercased())
            }.count
            chips.append(ChipModel(
                label: "MOOD", value: v, count: count,
                isPrimary: false, leading: .none,
                onRemove: { searchModel.clear() }
            ))
        }
        return chips
    }

    private var filterRow: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
                Text("FILTER")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
                    .tracking(1.5)
            }
            .padding(.trailing, 4)

            ForEach(activeChips) { chip in
                filterChipView(chip)
            }

            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.white.opacity(0.55))
                Text("filter")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .overlay(
                Capsule()
                    .strokeBorder(style: StrokeStyle(lineWidth: 0.5, dash: [3]))
                    .foregroundColor(.white.opacity(0.22))
            )

            Spacer()

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(filteredRecords.count)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                Text("MATCHES")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
                    .tracking(1)
            }

            if hasActiveFilters {
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 1, height: 12)

                Button(action: { searchModel.clear() }) {
                    Text("Clear all")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 5) {
                Text("SORT")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
                    .tracking(1)
                Text("recent")
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.5))
        }
    }

    @ViewBuilder
    private func filterChipView(_ chip: ChipModel) -> some View {
        let chipBg = chip.isPrimary
            ? rosePrimary.opacity(0.14)
            : Color.white.opacity(0.05)
        let chipBorder = chip.isPrimary
            ? rosePrimary.opacity(0.4)
            : Color.white.opacity(0.10)
        let labelColor = chip.isPrimary
            ? rosePale.opacity(0.9)
            : Color.white.opacity(0.45)

        HStack(spacing: 8) {
            Text(chip.label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(labelColor)
                .tracking(1)

            switch chip.leading {
            case .none:
                EmptyView()
            case .typeAa:
                Text("Aa")
                    .font(.custom("Instrument Serif", size: 14))
                    .foregroundColor(.white)
            case .colors(let swatches):
                HStack(spacing: 3) {
                    ForEach(Array(swatches.enumerated()), id: \.offset) { _, c in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(c)
                            .frame(width: 14, height: 14)
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.white.opacity(0.18), lineWidth: 0.5))
                    }
                }
            }

            Text(chip.value)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)

            if chip.count > 0 {
                Text("\(chip.count)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(chip.isPrimary ? .white : .white.opacity(0.7))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.white.opacity(chip.isPrimary ? 0.12 : 0.08)))
            }

            Button(action: chip.onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(.white.opacity(chip.isPrimary ? 0.9 : 0.55))
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.white.opacity(chip.isPrimary ? 0.10 : 0.06)))
            }
            .buttonStyle(.plain)
            .help("Remove filter")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(Capsule().fill(chipBg))
        .overlay(Capsule().stroke(chipBorder, lineWidth: 0.5))
    }

    // MARK: - Result rail

    private var resultRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(filteredRecords) { rec in
                    resultCard(rec)
                }
                if filteredRecords.isEmpty {
                    emptyState
                }
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 154)
        .overlay(alignment: .trailing) {
            LinearGradient(
                colors: [Color.black.opacity(0), Color.black],
                startPoint: .leading, endPoint: .trailing
            )
            .frame(width: 64)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func resultCard(_ rec: ScreenshotRecord) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Color.white.opacity(0.04)
                if let url = store.storedImageURL(for: rec),
                   let img = NSImage(contentsOf: url) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo")
                        .foregroundColor(.white.opacity(0.3))
                }
            }
            .frame(width: 192, height: 124)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5))
            .onTapGesture { openMainWindow() }
            .help(cardLabel(for: rec))

            HStack(spacing: 6) {
                Text(cardTitle(for: rec))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer(minLength: 0)
                paletteDots(for: rec)
            }
            .frame(width: 192)
        }
    }

    private func cardTitle(for rec: ScreenshotRecord) -> String {
        if let m = rec.metadata, !m.style.isEmpty {
            return "\(rec.relevance.surface) · \(m.style)"
        }
        return rec.relevance.surface
    }

    private func cardLabel(for rec: ScreenshotRecord) -> String {
        if let m = rec.metadata { return "\(m.style) · \(m.layout) · \(m.mood)" }
        return rec.relevance.surface
    }

    @ViewBuilder
    private func paletteDots(for rec: ScreenshotRecord) -> some View {
        HStack(spacing: 2) {
            ForEach(Array((rec.palette?.all.prefix(3) ?? []).enumerated()), id: \.offset) { _, hex in
                if let c = Color(hex: hex) {
                    Circle()
                        .fill(c)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
                }
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.stack")
                .font(.system(size: 22))
                .foregroundColor(.white.opacity(0.35))
            VStack(alignment: .leading, spacing: 2) {
                Text("No references yet")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text("Take a screenshot — RefVault will index it automatically.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.55))
            }
            Spacer()
        }
        .padding(16)
        .frame(height: 124)
        .background(RoundedRectangle(cornerRadius: 12)
            .fill(Color.white.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(style: StrokeStyle(lineWidth: 0.5, dash: [4]))
            .foregroundColor(.white.opacity(0.15)))
    }

    // MARK: - Helpers

    private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let win = NSApp.windows.first(where: {
            !$0.title.isEmpty || $0.contentViewController != nil
        }) {
            win.makeKeyAndOrderFront(nil)
        }
    }

    private func openWatchedFolder() {
        if let folder = ScreenshotWatcher.defaultFolders.first {
            NSWorkspace.shared.open(folder)
        }
    }
}

// MARK: - Color helpers

private extension Color {
    /// Map common Gemma color descriptors to representative swatches for
    /// the filter chip's leading color stops. Hex strings parse via the
    /// `Color(hex:)` initializer defined in LibraryView.swift.
    static func named(swatch raw: String) -> Color? {
        if let hex = Color(hex: raw) { return hex }
        switch raw.lowercased() {
        case "cream", "off-white", "ivory":   return Color(red: 0.957, green: 0.945, blue: 0.918)
        case "white":                          return .white
        case "black", "ink":                   return Color(red: 0.10, green: 0.10, blue: 0.10)
        case "warm", "amber":                  return Color(red: 0.788, green: 0.655, blue: 0.486)
        case "cool":                           return Color(red: 0.55, green: 0.65, blue: 0.78)
        case "dark":                           return Color(red: 0.10, green: 0.10, blue: 0.12)
        case "muted":                          return Color(red: 0.49, green: 0.49, blue: 0.51)
        case "vibrant":                        return Color(red: 1.0, green: 0.22, blue: 0.37)
        case "pastel":                         return Color(red: 0.92, green: 0.86, blue: 0.92)
        default: return nil
        }
    }
}
