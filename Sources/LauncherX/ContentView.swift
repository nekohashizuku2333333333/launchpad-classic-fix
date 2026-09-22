import SwiftUI
import AppKit

struct LauncherDisplayEntry: Identifiable {
    let id: String
    let entry: LauncherEntry?
}

struct FolderDisplayEntry: Identifiable {
    let id: String
    let app: AppItem?
}

enum LauncherDragProvider {
    static func make(for entry: LauncherEntry) -> NSItemProvider {
        if case .app(let app) = entry {
            // NSString treats our app: identifier as a URL. Register the real
            // file URL first so external destinations such as Dock receive it.
            let provider = NSItemProvider(object: app.url as NSURL)
            provider.registerObject(entry.id as NSString, visibility: .all)
            return provider
        }
        return NSItemProvider(object: entry.id as NSString)
    }
}

struct EntryDragPreview: View {
    let icon: NSImage?
    let iconSize: Double

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: iconSize * 0.4, weight: .light))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: iconSize, height: iconSize)
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
    }
}

struct FolderDragPreview: View {
    let icons: [NSImage]
    let size: Double

    var body: some View {
        let faceSize = size * 0.8
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3),
            spacing: 3
        ) {
            ForEach(0..<Self.previewSlotCount(iconCount: icons.count), id: \.self) { index in
                if icons.indices.contains(index) {
                    Image(nsImage: icons[index])
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: max(10, (faceSize - 22) / 3), height: max(10, (faceSize - 22) / 3))
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.white.opacity(0.16))
                        .overlay {
                            Image(systemName: "app.dashed")
                                .font(.system(size: max(8, size * 0.09), weight: .light))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .frame(height: max(10, (faceSize - 22) / 3))
                }
            }
        }
        .padding(8)
        .frame(width: faceSize, height: faceSize, alignment: .topLeading)
        .background(Color.white.opacity(0.48), in: RoundedRectangle(cornerRadius: faceSize * 0.22, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        .frame(width: size, height: size)
    }

    nonisolated static func previewSlotCount(iconCount: Int) -> Int {
        min(9, max(1, iconCount))
    }
}

struct ContentView: View {
    @EnvironmentObject var model: LauncherModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didRevealContent = false
    @State private var settingsHovered = false

    private var verticalMetrics: LaunchpadVerticalMetrics {
        LaunchpadVerticalMetrics(topSafeAreaInset: model.displayTopSafeAreaInset)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if model.isLauncherVisible {
                    LaunchpadBackground(size: geometry.size)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .ignoresSafeArea()
                    Color.clear
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture {
                            model.handleBackgroundClick()
                        }
                    ScrollWheelMonitor { model.navigateVisiblePages(by: $0) }
                    VStack(spacing: 0) {
                        searchField
                            .padding(.top, verticalMetrics.searchTopPadding)
                            .opacity(model.openGroupID == nil ? 1 : 0)
                            .allowsHitTesting(model.openGroupID == nil)
                            .accessibilityHidden(model.openGroupID != nil)
                        PagedAppGrid()
                    }
                    .opacity(didRevealContent ? 1 : 0)
                    .scaleEffect(didRevealContent ? 1 : (reduceMotion ? 1 : 1.04))
                    .offset(y: didRevealContent ? 0 : (reduceMotion ? 0 : -12))
                    .onAppear { revealContent() }
                    if model.pageCount > 1 {
                        VStack(spacing: 0) {
                            Spacer(minLength: 0)
                            LaunchpadPageIndicator(
                                pageCount: model.pageCount,
                                currentPage: min(model.currentPage, model.pageCount - 1),
                                onSelect: { model.goToPage($0) }
                            )
                            .padding(.bottom, 100)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .allowsHitTesting(model.openGroupID == nil)
                        .opacity(didRevealContent && model.openGroupID == nil ? 1 : 0)
                        .animation(
                            reduceMotion ? nil : .easeInOut(duration: 0.2),
                            value: model.openGroupID
                        )
                        .zIndex(100)
                    }
                }
            }
            .onChange(of: model.isLauncherVisible) { _, visible in
                if !visible {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { didRevealContent = false }
                }
            }
            .overlay(alignment: .topTrailing) {
                LauncherSettingsMenu()
                    .keyboardShortcut(",", modifiers: .command)
                    .padding(24)
                    .padding(.top, verticalMetrics.topSafeAreaInset)
                    .opacity(model.openGroupID == nil && (settingsHovered || model.showLauncherSettings) ? 1 : 0)
                    .onHover { settingsHovered = $0 }
                    .allowsHitTesting(model.openGroupID == nil)
            }
            .onAppear { model.applyReferenceDefaultIconSize(pageWidth: geometry.size.width) }
            .onChange(of: geometry.size.width) { _, width in
                model.applyReferenceDefaultIconSize(pageWidth: width)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(!model.isDismissing)
        .foregroundStyle(model.background == "light" ? Color.black : Color.white)
        .confirmationDialog(
            model.text(
                "Delete “\(model.pendingDeleteApp?.name ?? "")”?",
                "「\(model.pendingDeleteApp?.name ?? "")」を削除しますか？",
                "要刪除「\(model.pendingDeleteApp?.name ?? "")」嗎？"
            ),
            isPresented: Binding(
                get: { model.pendingDeleteApp != nil },
                set: { if !$0 { model.pendingDeleteApp = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(model.text("Delete", "削除", "刪除"), role: .destructive) {
                model.deletePendingApplication()
            }
            Button(model.text("Cancel", "キャンセル", "取消"), role: .cancel) {
                model.pendingDeleteApp = nil
            }
        } message: {
            Text(model.text(
                "The application will be moved to the Trash. You can reinstall it from the App Store.",
                "アプリケーションはゴミ箱へ移動します。App Storeから再インストールできます。",
                "應用程式會移到垃圾桶。你可以從 App Store 重新安裝。"
            ))
        }
        .alert(
            model.text("Operation Failed", "操作に失敗しました", "操作失敗"),
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.clearError() } }
            )
        ) {
            Button("OK") { model.clearError() }
        } message: {
            Text(model.errorMessage ?? model.text(
                "An unknown error occurred.",
                "不明なエラーが発生しました。",
                "發生未知錯誤。"
            ))
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.38), value: model.background)
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.24),
            value: model.selectedBackgroundImage != nil
        )
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if model.isLauncherVisible { model.maximizeLauncherWindow() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.handleApplicationDidResignActive()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in
            model.handleApplicationDidHide()
        }
        .onExitCommand { model.handleEscape() }

    }

    private func revealContent() {
        guard !didRevealContent else { return }
        withAnimation(.easeOut(duration: reduceMotion ? LaunchpadPageMotion.reducedMotionDuration : 0.35)) {
            didRevealContent = true
        }
    }

    private var searchField: some View {
        LaunchpadSearchField(
            text: $model.search,
            placeholder: model.text("Search", "検索", "搜尋"),
            clearButtonLabel: model.text("Clear Search", "検索を消去", "清除搜尋"),
            isAvailable: model.isLauncherVisible && !model.isDismissing
                && model.openGroupID == nil && !model.showLauncherSettings
                && model.pendingDeleteApp == nil && model.errorMessage == nil
                && !model.isDeleting && model.reorderDragSourceID == nil,
            reducesTransparency: model.reducesTransparency,
            usesDarkText: model.background == "light",
            onInteraction: { model.clearKeyboardSelection() },
            onSubmit: { model.activateKeyboardSelection() },
            onCancel: { model.handleEscape() }
        )
        .frame(width: 250, height: LaunchpadVerticalMetrics.searchFieldHeight)
    }
}

struct LauncherSettingsMenu: View {
    @EnvironmentObject var model: LauncherModel

    var body: some View {
        Button {
            model.showLauncherSettings.toggle()
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.text("Launcher Settings", "Launcher設定", "啟動器設定"))
        .popover(isPresented: $model.showLauncherSettings, arrowEdge: .top) {
            LauncherSettingsPopover()
                .environmentObject(model)
        }
    }
}

struct LauncherSettingsPopover: View {
    @EnvironmentObject var model: LauncherModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(model.text("Display", "表示", "顯示"), systemImage: "rectangle.grid.3x2")
                HStack(spacing: 8) {
                    sizeButton(72, en: "Small", ja: "小", zhHant: "小")
                    sizeButton(92, en: "Medium", ja: "中", zhHant: "中")
                    sizeButton(112, en: "Large", ja: "大", zhHant: "大")
                }
                HStack(spacing: 8) {
                    Button { model.adjustIconSize(by: -4) } label: {
                        Label(model.text("Smaller", "小さく", "縮小"), systemImage: "minus")
                            .frame(maxWidth: .infinity)
                    }
                    Button { model.adjustIconSize(by: 4) } label: {
                        Label(model.text("Larger", "大きく", "放大"), systemImage: "plus")
                            .frame(maxWidth: .infinity)
                    }
                }

                Divider()

                sectionHeader(model.text("Background", "背景", "背景"), systemImage: "photo")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    backgroundButton("wallpaper", en: "Desktop", ja: "デスクトップ", zhHant: "桌面")
                    backgroundButton("aurora", en: "Aurora", ja: "オーロラ", zhHant: "極光")
                    backgroundButton("ocean", en: "Ocean", ja: "オーシャン", zhHant: "海洋")
                    backgroundButton("dark", en: "Dark", ja: "ダーク", zhHant: "深色")
                    backgroundButton("light", en: "Light", ja: "ライト", zhHant: "淺色")
                }

                if !model.wallpapers.isEmpty {
                    DisclosureGroup {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(model.wallpapers) { wallpaper in
                                let value = "file:" + wallpaper.url.path
                                Button {
                                    model.background = value
                                } label: {
                                    selectionRow(wallpaper.name, selected: model.background == value)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 6)
                    } label: {
                        Label(model.text("macOS Wallpapers", "macOS壁紙", "macOS 桌布"), systemImage: "photo.stack")
                            .font(.system(size: 13, weight: .medium))
                    }
                }

                Divider()

                sectionHeader(model.text("Language", "言語", "語言"), systemImage: "globe")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    languageButton(
                        "system",
                        title: model.text("System", "システム", "系統")
                    )
                    languageButton("en", title: "English")
                    languageButton("ja", title: "日本語")
                    languageButton("zh-Hant", title: "繁體中文")
                }

                Divider()

                sectionHeader(model.text("Updates", "アップデート", "更新"), systemImage: "arrow.triangle.2.circlepath")
                Button {
                    NotificationCenter.default.post(name: .launcherCheckForUpdates, object: nil)
                } label: {
                    actionRow(
                        model.text("Check for Updates…", "アップデートを確認…", "檢查更新…"),
                        systemImage: "arrow.down.circle",
                        color: .secondary
                    )
                }
                .buttonStyle(.plain)

                Divider()

                Button {
                    NSApp.terminate(nil)
                } label: {
                    actionRow(
                        model.text("Quit Launchpad Classic", "Launchpad Classicを終了", "結束 Launchpad Classic"),
                        systemImage: "power",
                        color: .secondary
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q", modifiers: .command)
            }
            .padding(16)
        }
        .frame(width: 320, height: min(570, preferredHeight))
        .background(Color(nsColor: .windowBackgroundColor))
        .foregroundStyle(Color.primary)
    }

    private var preferredHeight: CGFloat {
        model.wallpapers.isEmpty ? 500 : 570
    }

    private func sectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func actionRow(
        _ title: String,
        systemImage: String,
        color: Color = .primary
    ) -> some View {
        Label(title, systemImage: systemImage)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
    }

    private func sizeButton(_ size: Double, en: String, ja: String, zhHant: String) -> some View {
        Button {
            model.setIconSize(size)
        } label: {
            selectionTile(model.text(en, ja, zhHant), selected: abs(model.iconSize - size) < 0.5)
        }
        .buttonStyle(.plain)
    }

    private func backgroundButton(_ value: String, en: String, ja: String, zhHant: String) -> some View {
        Button {
            model.background = value
        } label: {
            selectionTile(model.text(en, ja, zhHant), selected: model.background == value)
        }
        .buttonStyle(.plain)
    }

    private func languageButton(_ value: String, title: String) -> some View {
        Button {
            model.language = value
        } label: {
            selectionTile(title, selected: model.language == value)
        }
        .buttonStyle(.plain)
    }

    private func selectionTile(_ title: String, selected: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            Text(title).lineLimit(1)
        }
        .font(.system(size: 12, weight: selected ? .semibold : .regular))
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(
            selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7))
    }

    private func selectionRow(_ title: String, selected: Bool) -> some View {
        HStack(spacing: 7) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct PagedAppGrid: View {
    @EnvironmentObject var model: LauncherModel

    var body: some View {
        GeometryReader { geometry in
            let allEntries = model.rootEntries
            let metrics = LaunchpadLayoutMetrics.calculate(
                containerWidth: geometry.size.width,
                containerHeight: geometry.size.height,
                preferredIconSize: model.iconSize,
                topSafeAreaInset: model.displayTopSafeAreaInset
            )
            let pageCount = max(1, Int(ceil(Double(allEntries.count) / Double(metrics.capacity))))

            ZStack {
                RootPagerCanvas(
                    allEntries: allEntries,
                    pageCount: pageCount,
                    pageSize: metrics.capacity,
                    metrics: metrics
                )
                if allEntries.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: model.search.isEmpty ? "square.grid.3x3" : "magnifyingglass")
                            .font(.system(size: 32, weight: .light))
                        Text(model.search.isEmpty
                            ? model.text("No Applications Found", "アプリケーションが見つかりません", "找不到應用程式")
                            : model.text("No Results", "検索結果がありません", "找不到結果"))
                            .font(.headline)
                        if !model.search.isEmpty {
                            Text(model.text(
                                "Try a different search.",
                                "別のキーワードで検索してください。",
                                "請嘗試其他搜尋詞。"
                            ))
                            .font(.subheadline)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 70)
                    .allowsHitTesting(false)
                    .accessibilityElement(children: .combine)
                }
            }
            .onAppear { model.setPageCount(pageCount) }
            .onChange(of: pageCount) { _, count in model.setPageCount(count) }
        }
    }
}

/// A Sequoia folder replaces the root grid with a centred, full-width panel.
struct FolderPresentationState: Equatable {
    let group: AppGroup
    let folderApps: [AppItem]
    let contentMetrics: LaunchpadLayoutMetrics
    let pageCount: Int
    let bandWidth: CGFloat
    let bandHeight: CGFloat
    let bandCenterY: CGFloat

    var folderEntryID: String { "group:" + group.id.uuidString }
}

enum FolderPanelMetrics {
    static let verticalPadding = 46.0
    static let horizontalPadding = 40.0
    static let titleHeight = 36.0
    static let titleSpacing = 14.0
    static let indicatorHeight = 20.0
    static let indicatorSpacing = 10.0
    static let cornerRadius = 40.0
    static let minimumEdgeInset = 16.0
    static let minimumBandWidth = 360.0

    static func chromeHeight(includesIndicator: Bool) -> Double {
        verticalPadding * 2 + (includesIndicator ? indicatorHeight + indicatorSpacing : 0)
    }

    static func bandWidth(folderGridWidth: Double, canvasWidth: Double, sideMargin: Double) -> Double {
        min(canvasWidth - 24, max(folderGridWidth + horizontalPadding * 2, canvasWidth * (1300.0 / 1440.0)))
    }
}

struct RootPagerCanvas: View {
    @EnvironmentObject var model: LauncherModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat = 0
    let allEntries: [LauncherEntry]
    let pageCount: Int
    let pageSize: Int
    let metrics: LaunchpadLayoutMetrics

    private var verticalMetrics: LaunchpadVerticalMetrics {
        LaunchpadVerticalMetrics(topSafeAreaInset: model.displayTopSafeAreaInset)
    }

    var body: some View {
        GeometryReader { pagerGeometry in
            let pageWidth = max(1, pagerGeometry.size.width)
            let pageHeight = max(1, pagerGeometry.size.height)
            let activePage = min(model.displayedPage, pageCount - 1)
            let split = folderPresentationState(
                pageWidth: pageWidth,
                pageHeight: pageHeight,
                activePage: activePage
            )

            ZStack(alignment: .leading) {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(pageDragGesture(pageWidth: pageWidth))
                    .gesture(
                        TapGesture().onEnded {
                            if model.openGroupID == nil { model.handleBackgroundClick() }
                        }
                    )
                    .dropDestination(for: String.self) { items, location in
                        guard model.openGroupID == nil, let sourceID = items.first else { return false }
                        // Resolve the actual release point as well as hover: native
                        // drop delivery can arrive after the tracking timer stops.
                        return model.reorderToSlot(
                            sourceID,
                            page: activePage,
                            slot: metrics.insertionSlot(at: location, containerWidth: pageWidth),
                            pageSize: pageSize
                        )
                    }

                ForEach(
                    LaunchpadPageMotion.visiblePages(
                        currentPage: model.displayedPage,
                        pageCount: pageCount,
                        reduceMotion: reduceMotion
                    ),
                    id: \.self
                ) { page in
                    let pageSplit = page == activePage ? split : nil
                    RootPageRows(
                        page: page,
                        displayEntries: displayEntries(on: page),
                        metrics: metrics,
                        split: pageSplit,
                        pageWidth: pageWidth
                    )
                    .offset(
                        x: reduceMotion ? 0 : CGFloat(page - activePage) * pageWidth + dragOffset
                    )
                    .opacity(!reduceMotion || page == activePage ? 1 : 0)
                    // Remove outgoing drop targets immediately; only the new
                    // page fades in, so native drops cannot hit a fading page.
                    .transition(reduceMotion ? .asymmetric(insertion: .opacity, removal: .identity) : .identity)
                    .accessibilityHidden(page != activePage || model.openGroupID != nil)
                    .allowsHitTesting(page == model.displayedPage && split == nil && model.openGroupID == nil)
                    .compositingGroup()
                }

                if let split {
                    FolderOverlay(
                        split: split,
                        canvasWidth: pageWidth,
                        canvasHeight: pageHeight,
                        rootMetrics: metrics,
                        rootPageSize: pageSize,
                        activePage: activePage
                    )
                    .transition(.opacity)
                    .zIndex(10)
                }
            }
            .clipped()
            .onAppear { reportLayout(size: pagerGeometry.size) }
            .onChange(of: pagerGeometry.size) { _, size in reportLayout(size: size) }
            .onChange(of: metrics) { _, _ in reportLayout(size: pagerGeometry.size) }
            .onChange(of: pageSize) { _, _ in reportLayout(size: pagerGeometry.size) }
            .onChange(of: verticalMetrics) { _, _ in reportLayout(size: pagerGeometry.size) }
        }
    }

    private func reportLayout(size: CGSize) {
        model.updateRootPagerLayout(
            topOffset: verticalMetrics.pagerTopOffset,
            size: size,
            metrics: metrics,
            pageSize: pageSize
        )
    }

    private func folderPresentationState(
        pageWidth: CGFloat,
        pageHeight: CGFloat,
        activePage: Int
    ) -> FolderPresentationState? {
        guard model.search.isEmpty,
              let group = model.group(for: model.openGroupID) else { return nil }
        let folderID = "group:" + group.id.uuidString
        guard let index = allEntries.firstIndex(where: { $0.id == folderID }),
              index / pageSize == activePage else { return nil }

        let folderApps = model.apps(in: group)
        let available = max(metrics.cellHeight + FolderPanelMetrics.verticalPadding * 2, pageHeight - 84)
        var rowLimit = min(LaunchpadLayoutMetrics.folderMaximumRows,
            metrics.rowsFitting(availableHeight: available - FolderPanelMetrics.chromeHeight(includesIndicator: false)))
        var content = LaunchpadLayoutMetrics.folderContent(base: metrics, itemCount: folderApps.count, rowLimit: rowLimit)
        var folderPageCount = content.pageCount(forItemCount: folderApps.count)
        if folderPageCount > 1 {
            rowLimit = min(LaunchpadLayoutMetrics.folderMaximumRows,
                metrics.rowsFitting(availableHeight: available - FolderPanelMetrics.chromeHeight(includesIndicator: true)))
            content = LaunchpadLayoutMetrics.folderContent(base: metrics, itemCount: folderApps.count, rowLimit: rowLimit)
            folderPageCount = content.pageCount(forItemCount: folderApps.count)
        }
        let bandHeight = FolderPanelMetrics.chromeHeight(includesIndicator: folderPageCount > 1) + content.gridHeight
        let bandWidth = FolderPanelMetrics.bandWidth(folderGridWidth: content.gridWidth, canvasWidth: pageWidth,
            sideMargin: LaunchpadLayoutMetrics.sideMargin(forContainerWidth: pageWidth))
        // The pager already excludes the safe top strip. Keep the panel
        // centred in that usable screen area, with its title below the strip.
        let centerY = max(bandHeight / 2 + 12, (pageHeight - LaunchpadVerticalMetrics.referencePagerTopOffset) / 2 - 5)
        return FolderPresentationState(
            group: group, folderApps: folderApps, contentMetrics: content,
            pageCount: folderPageCount, bandWidth: bandWidth, bandHeight: bandHeight,
            bandCenterY: centerY
        )
    }

    private func displayEntries(on page: Int) -> [LauncherDisplayEntry] {
        let pageEntries = Array(entries(on: page))
        let sourceID = model.reorderDragSourceID
        var result = pageEntries
            .filter { $0.id != sourceID }
            .map { LauncherDisplayEntry(id: $0.id, entry: $0) }
        if let sourceID, model.openGroupID == nil,
           let preview = model.reorderPreview,
           preview.sourceID == sourceID, preview.page == page {
            let visualSlot = preview.slot
                - pageEntries.prefix(preview.slot).filter { $0.id == sourceID }.count
            result.insert(
                LauncherDisplayEntry(id: "reorder-gap", entry: nil),
                at: min(max(0, visualSlot), result.count)
            )
        }
        return Array(result.prefix(pageSize))
    }

    private func entries(on page: Int) -> ArraySlice<LauncherEntry> {
        let start = min(page * pageSize, allEntries.count)
        let end = min(start + pageSize, allEntries.count)
        return allEntries[start..<end]
    }

    private func pageDragGesture(pageWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard model.openGroupID == nil else { return }
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > abs(vertical) else { return }
                let isPastFirstPage = model.currentPage == 0 && horizontal > 0
                let isPastLastPage = model.currentPage == pageCount - 1 && horizontal < 0
                let resistance: CGFloat = (isPastFirstPage || isPastLastPage) ? 0.22 : 1
                let limit = pageWidth * 0.42
                dragOffset = reduceMotion ? 0 : min(max(horizontal * resistance, -limit), limit)
            }
            .onEnded { value in
                guard model.openGroupID == nil else {
                    dragOffset = 0
                    return
                }
                let horizontal = value.translation.width
                let vertical = value.translation.height
                let projected = value.predictedEndTranslation.width
                let animationVelocity = LaunchpadPageMotion.normalizedInitialVelocity(
                    translation: horizontal,
                    projectedTranslation: projected,
                    pageWidth: pageWidth
                )

                let threshold = max(72, pageWidth * LaunchpadPageMotion.pageDecisionRatio)
                let shouldChangePage = abs(horizontal) > abs(vertical)
                    && (abs(horizontal) >= threshold || abs(projected) >= threshold)
                let directionSource = abs(projected) >= abs(horizontal) ? projected : horizontal

                if shouldChangePage {
                    let delta = directionSource < 0 ? 1 : -1
                    if reduceMotion {
                        dragOffset = 0
                        model.changePage(by: delta)
                    } else {
                        withAnimation(LaunchpadPageMotion.animation(initialVelocity: animationVelocity)) {
                            dragOffset = 0
                            model.setCurrentPage(model.currentPage + delta)
                        }
                    }
                } else {
                    withAnimation(reduceMotion ? nil : LaunchpadPageMotion.animation()) {
                        dragOffset = 0
                    }
                }
            }
    }
}

/// Every tile belongs to one identity scope, including when it crosses a row.
/// Row-scoped stacks would destroy and recreate the moving tile at that edge.
struct RootPageRows: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let page: Int
    let displayEntries: [LauncherDisplayEntry]
    let metrics: LaunchpadLayoutMetrics
    let split: FolderPresentationState?
    let pageWidth: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(displayEntries.enumerated()), id: \.element.id) { index, display in
                ZStack {
                    if let entry = display.entry {
                        AppCell(
                            page: page,
                            entry: entry,
                            metrics: metrics,
                            isHidden: entry.id == split?.folderEntryID
                        )
                    } else {
                        Color.clear
                    }
                }
                .frame(width: metrics.cellWidth, height: metrics.cellHeight)
                .offset(
                    x: (pageWidth - metrics.gridWidth) / 2
                        + CGFloat(index % metrics.columns) * metrics.columnStride,
                    y: metrics.topInset + CGFloat(index / metrics.columns) * metrics.rowStride
                )
                .transition(.identity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(split != nil ? 0 : 1)
        .animation(
            reduceMotion
                ? .easeInOut(duration: LaunchpadPageMotion.reducedMotionDuration)
                : .spring(response: 0.4, dampingFraction: 0.88),
            value: split
        )
        .animation(
            LaunchpadReorderMotion.animation(reduceMotion: reduceMotion),
            value: displayEntries.map(\.id)
        )
    }
}

private enum LaunchpadReorderMotion {
    static func animation(reduceMotion: Bool) -> Animation {
        // A brief, non-bouncing response keeps the insertion boundary legible
        // with Reduce Motion, without the jump caused by disabling it entirely.
        reduceMotion
            ? .easeOut(duration: 0.14)
            : .spring(response: 0.26, dampingFraction: 1)
    }
}

struct LaunchpadPageIndicator: View {
    @EnvironmentObject var model: LauncherModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let pageCount: Int
    let currentPage: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<max(0, pageCount), id: \.self) { page in
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(page == currentPage ? 1 : 0.4))
                        .frame(
                            width: 6,
                            height: 6
                        )
                        .shadow(color: .black.opacity(0.38), radius: 1.5, y: 1)
                }
                .frame(width: 18, height: 20)
                .contentShape(Rectangle())
                .onTapGesture { onSelect(page) }
                .accessibilityLabel(model.text(
                    "Page \(page + 1) of \(pageCount)",
                    "\(pageCount)ページ中\(page + 1)ページ",
                    "第 \(page + 1) 頁，共 \(pageCount) 頁"
                ))
                .accessibilityAddTraits(page == currentPage ? [.isButton, .isSelected] : .isButton)
            }
        }
        .frame(height: 20)
        .animation(reduceMotion ? nil : LaunchpadPageMotion.animation(), value: currentPage)
    }
}

/// Unified grid cell (icon + label) with fixed layout bounds. Apps and
/// folders occupy identical cells so their columns, label baselines and
/// drag hitboxes always align.
struct AppCell: View {
    @EnvironmentObject var model: LauncherModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let page: Int
    let entry: LauncherEntry
    let metrics: LaunchpadLayoutMetrics
    var isHidden = false

    var body: some View {
        ZStack {
            centerContent
                .contentShape(Rectangle())
                .onTapGesture {
                    model.activateFromPointer(entry)
                }
                .onDrag {
                    model.startReorderDrag(entry.id)
                    return LauncherDragProvider.make(for: entry)
                } preview: {
                    dragPreview
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let sourceID = items.first else { return false }
                    guard model.openGroupID == nil, page == model.displayedPage else { return false }
                    model.handleDrop(sourceID, on: entry)
                    return true
                }
                .contextMenu {
                    if case .app(let app) = entry, app.isDeletable {
                        Button(model.text(
                            "Delete Application…",
                            "アプリケーションを削除…",
                            "刪除應用程式…"
                        ), role: .destructive) {
                            model.requestDeleteApplication(app)
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(accessibilityHint)
                .accessibilityAddTraits(model.highlightedEntryID == entry.id ? [.isButton, .isSelected] : .isButton)
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.65, maximumDistance: 8)
                        .onEnded { _ in model.beginEditing() }
                )
                .accessibilityAction(named: Text(model.text("Edit Applications", "アプリケーションを編集", "編輯應用程式"))) {
                    model.beginEditing()
                }

            if metrics.sideDropWidth > 1 {
                HStack(spacing: 0) {
                    sideDropZone(width: metrics.sideDropWidth, after: false)
                    Spacer(minLength: 0)
                    sideDropZone(width: metrics.sideDropWidth, after: true)
                }
            }
        }
        .frame(width: metrics.cellWidth, height: metrics.cellHeight)
        .modifier(LaunchpadTileDecoration(
            identifier: entry.id,
            app: { if case .app(let app) = entry { return app }; return nil }(),
            metrics: metrics
        ))
        .opacity(isHidden ? 0 : 1)
        .scaleEffect(isHidden && !reduceMotion ? 1.3 : 1)
        .animation(
            reduceMotion
                ? .easeInOut(duration: 0.16)
                : .spring(response: 0.4, dampingFraction: 0.85),
            value: isHidden
        )
    }

    @ViewBuilder
    private var centerContent: some View {
        switch entry {
        case .app(let app):
            AppIconCellContent(app: app, metrics: metrics)
        case .group(let group):
            VStack(spacing: LaunchpadLayoutMetrics.iconLabelPadding) {
                FolderIconArtwork(group: group, size: metrics.iconSize)
                cellLabel(group.name)
            }
            .frame(width: metrics.cellWidth, height: metrics.cellHeight)
        }
    }

    private func cellLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: LaunchpadLayoutMetrics.labelFontSize, weight: .regular))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity)
            .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
    }

    private func sideDropZone(width: CGFloat, after: Bool) -> some View {
        Color.clear
            .frame(width: width)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                guard let sourceID = items.first else { return false }
                guard model.openGroupID == nil, page == model.displayedPage else { return false }
                return model.reorder(sourceID, beside: entry.id, after: after)
            }
    }

    private var dragPreview: some View {
        let size = metrics.iconSize * 1.12
        switch entry {
        case .app(let app):
            return AnyView(EntryDragPreview(icon: model.cachedIcon(for: app), iconSize: size))
        case .group(let group):
            let icons = model.apps(in: group).prefix(9).compactMap { model.cachedIcon(for: $0) }
            return AnyView(FolderDragPreview(icons: Array(icons), size: size))
        }
    }

    private var accessibilityLabel: String {
        switch entry {
        case .app(let app): app.name
        case .group(let group): group.name
        }
    }

    private var accessibilityHint: String {
        switch entry {
        case .app:
            model.text("Opens the application", "アプリケーションを開きます", "開啟應用程式")
        case .group:
            model.text("Opens the folder", "フォルダを開きます", "開啟資料夾")
        }
    }
}

/// Icon + label pair for a regular application, sized by the shared metrics.
struct AppIconCellContent: View {
    let app: AppItem
    let metrics: LaunchpadLayoutMetrics

    var body: some View {
        VStack(spacing: LaunchpadLayoutMetrics.iconLabelPadding) {
            ApplicationArtwork(app: app, size: metrics.iconSize)
            Text(app.name)
                .font(.system(size: LaunchpadLayoutMetrics.labelFontSize, weight: .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity)
                .shadow(color: .black.opacity(0.7), radius: 2, y: 1)
        }
        .frame(width: metrics.cellWidth, height: metrics.cellHeight)
    }
}

/// Folder artwork only: the mini-icon preview square that draws inside a
/// cell without influencing the surrounding grid layout.
struct FolderIconArtwork: View {
    @EnvironmentObject var model: LauncherModel
    let group: AppGroup
    let size: Double
    private var preview: [AppItem] { Array(model.apps(in: group).prefix(9)) }

    var body: some View {
        let faceSize = size * 0.8
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3),
            spacing: 3
        ) {
            ForEach(preview) { app in
                ApplicationArtwork(app: app, size: max(10, (faceSize - 22) / 3))
            }
        }
        .padding(8)
        .frame(width: faceSize, height: faceSize, alignment: .topLeading)
        .background(Color.white.opacity(model.reducesTransparency ? 0.62 : 0.48),
            in: RoundedRectangle(cornerRadius: faceSize * 0.22, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
        .frame(width: size, height: size)
    }

}

struct ApplicationArtwork: View {
    @EnvironmentObject var model: LauncherModel
    let app: AppItem
    let size: Double
    @StateObject private var state = ApplicationArtworkState()

    var body: some View {
        let request = ApplicationArtworkRequest(
            appID: app.id,
            isLauncherVisible: model.isLauncherVisible
        )
        let preparedIcon = state.representedAppID == app.id
            ? state.icon ?? model.cachedIcon(for: app)
            : model.cachedIcon(for: app)
        Group {
            if let icon = preparedIcon {
                if model.iconNeedsRoundedCorners(for: app) {
                    renderedIcon(icon).clipShape(
                        RoundedRectangle(cornerRadius: max(2, size * 0.2245), style: .continuous)
                    )
                } else {
                    renderedIcon(icon)
                }
            } else {
                RoundedRectangle(cornerRadius: max(4, size * 0.2))
                    .fill(.thinMaterial)
                    .overlay {
                        Image(systemName: "app.dashed")
                            .font(.system(size: max(10, size * 0.36), weight: .light))
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .frame(width: size, height: size)
        .task(id: request) {
            guard model.isLauncherVisible else { return }
            guard state.prepareToLoad(appID: app.id) else { return }
            let loadedIcon = await model.loadIcon(for: app)
            guard !Task.isCancelled, model.isLauncherVisible else { return }
            state.finishLoading(loadedIcon, appID: app.id)
        }
        .onDisappear { state.releaseIcon() }
    }

    private func renderedIcon(_ icon: NSImage) -> some View {
        Image(nsImage: icon)
            .interpolation(.high)
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}

private struct ApplicationArtworkRequest: Hashable {
    let appID: String
    let isLauncherVisible: Bool
}

@MainActor
final class ApplicationArtworkState: ObservableObject {
    @Published private(set) var icon: NSImage?
    @Published private(set) var representedAppID: String?

    func prepareToLoad(appID: String) -> Bool {
        if representedAppID == appID, icon != nil { return false }
        representedAppID = appID
        icon = nil
        return true
    }

    func finishLoading(_ icon: NSImage, appID: String) {
        guard representedAppID == appID else { return }
        self.icon = icon
    }

    func releaseIcon() {
        icon = nil
        representedAppID = nil
    }
}

/// The folder panel and its outside drop regions share the root coordinate
/// space, so the current drag can continue into the root grid on exit.
struct FolderOverlay: View {
    @EnvironmentObject var model: LauncherModel
    let split: FolderPresentationState
    let canvasWidth: CGFloat
    let canvasHeight: CGFloat
    let rootMetrics: LaunchpadLayoutMetrics
    let rootPageSize: Int
    let activePage: Int

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { model.handleBackgroundClick() }

        outsideBandDropRegions

        FolderPanel(split: split, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
            .position(x: canvasWidth / 2, y: split.bandCenterY)
    }

    private var outsideBandDropRegions: some View {
        let bandMinX = (canvasWidth - split.bandWidth) / 2
        let bandMaxX = bandMinX + split.bandWidth
        let bandMinY = split.bandCenterY - split.bandHeight / 2
        let bandMaxY = bandMinY + split.bandHeight

        return ZStack(alignment: .topLeading) {
            outsideDropRegion(
                x: 0,
                y: 0,
                width: canvasWidth,
                height: max(0, bandMinY)
            )
            outsideDropRegion(
                x: 0,
                y: bandMaxY,
                width: canvasWidth,
                height: max(0, canvasHeight - bandMaxY)
            )
            outsideDropRegion(
                x: 0,
                y: bandMinY,
                width: max(0, bandMinX),
                height: split.bandHeight
            )
            outsideDropRegion(
                x: bandMaxX,
                y: bandMinY,
                width: max(0, canvasWidth - bandMaxX),
                height: split.bandHeight
            )
        }
        .frame(width: canvasWidth, height: canvasHeight, alignment: .topLeading)
    }

    private func outsideDropRegion(
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat
    ) -> some View {
        Color.clear
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .onTapGesture { model.handleBackgroundClick() }
            .dropDestination(for: String.self) { items, location in
                guard width > 0, height > 0, let sourceID = items.first else { return false }
                let canvasPoint = CGPoint(
                    x: x + location.x,
                    y: y + location.y
                )
                let slot = rootSlot(at: canvasPoint)
                return model.moveOutOfOpenGroupToSlot(
                    sourceID,
                    page: activePage,
                    slot: slot,
                    pageSize: rootPageSize
                )
            }
            // Keep the drop location local to this rectangle. Applying
            // position first makes the callback use the enclosing canvas.
            .position(x: x + width / 2, y: y + height / 2)
    }

    private func rootSlot(at point: CGPoint) -> Int {
        rootMetrics.insertionSlot(at: point, containerWidth: canvasWidth)
    }

}

struct FolderPanel: View {
    @EnvironmentObject var model: LauncherModel
    @EnvironmentObject var folderPager: FolderPagerState
    let split: FolderPresentationState
    let canvasWidth: CGFloat
    let canvasHeight: CGFloat

    private var verticalMetrics: LaunchpadVerticalMetrics {
        LaunchpadVerticalMetrics(topSafeAreaInset: model.displayTopSafeAreaInset)
    }

    var body: some View {
        VStack(spacing: FolderPanelMetrics.indicatorSpacing) {
            FolderPagerCanvas(
                group: split.group,
                folderApps: split.folderApps,
                capacity: split.contentMetrics.capacity,
                pageCount: split.pageCount,
                metrics: split.contentMetrics,
                pageWidth: split.bandWidth - FolderPanelMetrics.horizontalPadding * 2
            )
            .frame(height: split.contentMetrics.gridHeight)
            .clipped()

            if split.pageCount > 1 {
                LaunchpadPageIndicator(
                    pageCount: split.pageCount,
                    currentPage: min(folderPager.page, split.pageCount - 1),
                    onSelect: { model.goToFolderPage($0) }
                )
                .frame(height: FolderPanelMetrics.indicatorHeight)
            }
        }
        .padding(.horizontal, FolderPanelMetrics.horizontalPadding)
        .padding(.vertical, FolderPanelMetrics.verticalPadding)
        .frame(width: split.bandWidth, height: split.bandHeight)
        .overlay(alignment: .top) {
            FolderTitleEditor(groupID: split.group.id, initialName: split.group.name)
                .frame(height: FolderPanelMetrics.titleHeight)
                .offset(y: -FolderPanelMetrics.titleHeight - FolderPanelMetrics.titleSpacing)
        }
        .background(bandBackdrop)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let sourceID = items.first else { return false }
            return model.addToOpenGroup(sourceID)
        }
        .onAppear {
            model.setFolderPageCount(split.pageCount)
            reportFolderLayout()
        }
        .onChange(of: split.pageCount) { _, count in model.setFolderPageCount(count) }
        .onChange(of: split) { _, _ in reportFolderLayout() }
        .onChange(of: verticalMetrics) { _, _ in reportFolderLayout() }
    }

    private var bandBackdrop: some View {
        RoundedRectangle(cornerRadius: FolderPanelMetrics.cornerRadius, style: .continuous)
            .fill(Color.white.opacity(model.reducesTransparency ? 0.62 : 0.48))
    }

    private func reportFolderLayout() {
        let bandMinY = split.bandCenterY - split.bandHeight / 2
        let gridOriginX = (canvasWidth - split.contentMetrics.gridWidth) / 2
        let gridOriginY = verticalMetrics.pagerTopOffset
            + bandMinY + FolderPanelMetrics.verticalPadding
        model.updateFolderPagerLayout(
            origin: CGPoint(x: gridOriginX, y: gridOriginY),
            cellWidth: split.contentMetrics.cellWidth,
            columnCount: split.contentMetrics.columns,
            capacity: split.contentMetrics.capacity,
            columnSpacing: split.contentMetrics.horizontalSpacing,
            rowSpacing: split.contentMetrics.verticalSpacing,
            itemHeight: split.contentMetrics.cellHeight,
            bandFrame: CGRect(
                x: (canvasWidth - split.bandWidth) / 2,
                y: verticalMetrics.pagerTopOffset + bandMinY,
                width: split.bandWidth,
                height: split.bandHeight
            )
        )
    }
}

struct FolderTitleEditor: View {
    @EnvironmentObject var model: LauncherModel
    let groupID: UUID
    let initialName: String
    @FocusState private var isFieldFocused: Bool
    @State private var isEditing = false
    @State private var draftName = ""

    var body: some View {
        ZStack {
            TextField(
                model.text("Folder Name", "フォルダ名", "資料夾名稱"),
                text: $draftName
            )
            .textFieldStyle(.plain)
            .font(.system(size: 28, weight: .light))
            .multilineTextAlignment(.center)
            .lineLimit(1)
            .truncationMode(.tail)
            .focused($isFieldFocused)
            .frame(maxWidth: .infinity)
            .opacity(isEditing ? 1 : 0)
            .disabled(!isEditing)
            .onSubmit { endEditing(commit: true) }

            if !isEditing {
                HStack(spacing: 7) {
                    Text(currentName)
                        .font(.system(size: 28, weight: .light))
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { beginEditing() }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .onExitCommand {
            if isEditing { endEditing(commit: false) }
        }
        .onChange(of: isFieldFocused) { wasFocused, isFocused in
            if wasFocused && !isFocused && isEditing {
                endEditing(commit: true)
            }
        }
        .accessibilityLabel(model.text("Rename Folder", "フォルダ名を変更", "重新命名資料夾"))
        .accessibilityHint(model.text(
            "Tap the folder name to edit it",
            "フォルダ名をタップして編集します",
            "點按資料夾名稱即可編輯"
        ))
        .accessibilityAddTraits(.isButton)
    }

    private var currentName: String {
        model.group(for: groupID)?.name ?? initialName
    }

    private func beginEditing() {
        guard !isEditing else { return }
        draftName = currentName
        isEditing = true
        DispatchQueue.main.async {
            isFieldFocused = true
        }
    }

    private func endEditing(commit: Bool) {
        guard isEditing else { return }
        isEditing = false
        isFieldFocused = false
        if commit {
            let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != currentName {
                model.renameGroup(groupID, to: trimmed)
                model.finalizeGroupName(groupID)
            }
        }
        draftName = ""
    }
}

final class FolderRenamePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FolderRenamePanelCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isPresenting = false
    private(set) var activePanel: FolderRenamePanel?
    private(set) var activeTextField: NSTextField?
    private weak var parentWindow: NSWindow?
    private weak var model: LauncherModel?
    private var groupID: UUID?

    func present(
        groupID: UUID,
        currentName: String,
        model: LauncherModel,
        parentWindow: NSWindow? = nil
    ) {
        if let activePanel {
            NSApp.activate()
            activePanel.makeKeyAndOrderFront(nil)
            focusNameField()
            return
        }
        guard model.group(for: groupID) != nil else {
            model.errorMessage = model.text(
                "This folder no longer exists.",
                "このフォルダは存在しません。",
                "此資料夾已不存在。"
            )
            return
        }

        let resolvedParent = parentWindow
            ?? NSApp.keyWindow
            ?? NSApp.windows.first(where: { $0.isVisible && !($0 is FolderRenamePanel) })
        let panel = makePanel(currentName: currentName, model: model)
        self.parentWindow = resolvedParent
        self.model = model
        self.groupID = groupID
        activePanel = panel
        isPresenting = true

        if let resolvedParent {
            resolvedParent.addChildWindow(panel, ordered: .above)
            let origin = NSPoint(
                x: resolvedParent.frame.midX - panel.frame.width / 2,
                y: resolvedParent.frame.midY - panel.frame.height / 2
            )
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }

        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        focusNameField()
    }

    @objc func saveRename() {
        guard let groupID, let model, let activeTextField else {
            dismissPanel()
            return
        }
        _ = Self.applyRename(groupID: groupID, name: activeTextField.stringValue, model: model)
        dismissPanel()
    }

    @objc func cancelRename() {
        dismissPanel()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === activePanel else { return }
        parentWindow?.removeChildWindow(closingWindow)
        clearSession()
    }

    @discardableResult
    static func applyRename(groupID: UUID, name: String, model: LauncherModel) -> Bool {
        guard model.group(for: groupID) != nil else { return false }
        model.renameGroup(groupID, to: name)
        model.finalizeGroupName(groupID)
        return model.group(for: groupID)?.name != nil
    }

    private func makePanel(currentName: String, model: LauncherModel) -> FolderRenamePanel {
        let panel = FolderRenamePanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = model.text("Rename Folder", "フォルダ名を変更", "重新命名資料夾")
        panel.level = .modalPanel
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.delegate = self

        let titleLabel = NSTextField(labelWithString: model.text("Folder Name", "フォルダ名", "資料夾名稱"))
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)

        let descriptionLabel = NSTextField(labelWithString: model.text(
            "Enter a new name, then select Save.",
            "新しい名前を入力して「保存」を選択してください。",
            "輸入新名稱，然後選取「儲存」。"
        ))
        descriptionLabel.font = .systemFont(ofSize: 13)
        descriptionLabel.textColor = .secondaryLabelColor

        let textField = NSTextField(string: currentName)
        textField.font = .systemFont(ofSize: 16, weight: .medium)
        textField.usesSingleLineMode = true
        textField.maximumNumberOfLines = 1
        textField.lineBreakMode = .byTruncatingTail
        textField.placeholderString = model.text("Folder Name", "フォルダ名", "資料夾名稱")
        textField.setAccessibilityLabel(model.text("Folder Name", "フォルダ名", "資料夾名稱"))
        activeTextField = textField

        let cancelButton = NSButton(
            title: model.text("Cancel", "キャンセル", "取消"),
            target: self,
            action: #selector(cancelRename)
        )
        cancelButton.keyEquivalent = "\u{1b}"
        let saveButton = NSButton(
            title: model.text("Save", "保存", "儲存"),
            target: self,
            action: #selector(saveRename)
        )
        saveButton.keyEquivalent = "\r"
        saveButton.bezelStyle = .rounded

        let buttonStack = NSStackView(views: [cancelButton, saveButton])
        buttonStack.orientation = .horizontal
        buttonStack.alignment = .centerY
        buttonStack.spacing = 10

        let contentView = NSView()
        panel.contentView = contentView
        for view in [titleLabel, descriptionLabel, textField, buttonStack] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 22),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 26),
            descriptionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            descriptionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            descriptionLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -26),
            textField.topAnchor.constraint(equalTo: descriptionLabel.bottomAnchor, constant: 16),
            textField.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -26),
            textField.heightAnchor.constraint(equalToConstant: 28),
            buttonStack.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 18),
            buttonStack.trailingAnchor.constraint(equalTo: textField.trailingAnchor),
            buttonStack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -18)
        ])
        panel.initialFirstResponder = textField
        return panel
    }

    private func focusNameField() {
        guard let activePanel, let activeTextField else { return }
        if activePanel.makeFirstResponder(activeTextField) {
            activeTextField.selectText(nil)
            return
        }
        Task { @MainActor [weak activePanel, weak activeTextField] in
            await Task.yield()
            guard let activePanel, let activeTextField else { return }
            if activePanel.makeFirstResponder(activeTextField) {
                activeTextField.selectText(nil)
            }
        }
    }

    private func dismissPanel() {
        guard let activePanel else {
            clearSession()
            return
        }
        activePanel.delegate = nil
        parentWindow?.removeChildWindow(activePanel)
        activePanel.orderOut(nil)
        activePanel.close()
        clearSession()
    }

    private func clearSession() {
        activePanel = nil
        activeTextField = nil
        parentWindow = nil
        model = nil
        groupID = nil
        isPresenting = false
    }
}

struct FolderPagerCanvas: View {
    @EnvironmentObject var model: LauncherModel
    @EnvironmentObject var folderPager: FolderPagerState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat = 0
    let group: AppGroup
    let folderApps: [AppItem]
    let capacity: Int
    let pageCount: Int
    let metrics: LaunchpadLayoutMetrics
    let pageWidth: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(pageDragGesture)
                .dropDestination(for: String.self) { items, location in
                    guard let sourceID = items.first else { return false }
                    return model.dropInOpenGroup(
                        sourceID,
                        page: min(folderPager.page, pageCount - 1),
                        capacity: capacity,
                        slot: metrics.insertionSlot(at: location, containerWidth: pageWidth)
                    )
                }


            ForEach(
                LaunchpadPageMotion.visiblePages(
                    currentPage: folderPager.displayedPage,
                    pageCount: pageCount,
                    reduceMotion: reduceMotion
                ),
                id: \.self
            ) { page in
                FolderAppGrid(
                    page: page,
                    group: group,
                    displayApps: displayApps(on: page),
                    metrics: metrics
                )
                .frame(maxWidth: .infinity, alignment: .top)
                .offset(
                    x: reduceMotion ? 0 : CGFloat(page - min(folderPager.displayedPage, pageCount - 1)) * pageWidth + dragOffset
                )
                .opacity(!reduceMotion || page == folderPager.displayedPage ? 1 : 0)
                .transition(reduceMotion ? .asymmetric(insertion: .opacity, removal: .identity) : .identity)
                .accessibilityHidden(page != folderPager.displayedPage)
                .allowsHitTesting(page == folderPager.displayedPage)
                .compositingGroup()
            }
        }
    }

    private func displayApps(on page: Int) -> [FolderDisplayEntry] {
        let pageApps = Array(apps(on: page))
        let sourceID = model.reorderDragSourceID
        var result = pageApps
            .filter { $0.id != sourceID }
            .map { FolderDisplayEntry(id: $0.id, app: $0) }
        if let sourceID,
           let preview = model.reorderPreview,
           preview.sourceID == sourceID, preview.page == page {
            let visualSlot = preview.slot
                - pageApps.prefix(preview.slot).filter { $0.id == sourceID }.count
            result.insert(
                FolderDisplayEntry(id: "reorder-gap", app: nil),
                at: min(max(0, visualSlot), result.count)
            )
        }
        return result
    }

    private var pageDragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) > abs(vertical) else { return }
                let isPastFirstPage = folderPager.page == 0 && horizontal > 0
                let isPastLastPage = folderPager.page == pageCount - 1 && horizontal < 0
                let resistance: CGFloat = (isPastFirstPage || isPastLastPage) ? 0.22 : 1
                let limit = pageWidth * 0.42
                dragOffset = reduceMotion ? 0 : min(max(horizontal * resistance, -limit), limit)
            }
            .onEnded { value in
                let horizontal = value.translation.width
                let vertical = value.translation.height
                let projected = value.predictedEndTranslation.width
                let animationVelocity = LaunchpadPageMotion.normalizedInitialVelocity(
                    translation: horizontal,
                    projectedTranslation: projected,
                    pageWidth: pageWidth
                )

                let shouldChangePage = abs(horizontal) > abs(vertical)
                    && (abs(horizontal) >= 42 || abs(projected) >= 110)
                let directionSource = abs(projected) >= abs(horizontal) ? projected : horizontal
                let delta = directionSource < 0 ? 1 : -1

                if shouldChangePage {
                    if reduceMotion {
                        dragOffset = 0
                        model.goToFolderPage(folderPager.page + delta)
                    } else {
                        withAnimation(LaunchpadPageMotion.animation(initialVelocity: animationVelocity)) {
                            dragOffset = 0
                            model.setFolderPage(folderPager.page + delta)
                        }
                    }
                } else {
                    withAnimation(reduceMotion ? nil : LaunchpadPageMotion.animation()) {
                        dragOffset = 0
                    }
                }
            }
    }

    private func apps(on page: Int) -> ArraySlice<AppItem> {
        let start = min(page * capacity, folderApps.count)
        let end = min(start + capacity, folderApps.count)
        return folderApps[start..<end]
    }
}

struct FolderAppGrid: View {
    let page: Int
    let group: AppGroup
    let displayApps: [FolderDisplayEntry]
    let metrics: LaunchpadLayoutMetrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(displayApps.enumerated()), id: \.element.id) { index, display in
                ZStack {
                    if let app = display.app {
                        FolderAppTile(page: page, group: group, app: app, metrics: metrics)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: metrics.cellWidth, height: metrics.cellHeight)
                .offset(
                    x: CGFloat(index % metrics.columns) * metrics.columnStride,
                    y: CGFloat(index / metrics.columns) * metrics.rowStride
                )
                .transition(.identity)
            }
        }
        .animation(
            LaunchpadReorderMotion.animation(reduceMotion: reduceMotion),
            value: displayApps.map(\.id)
        )
        .frame(width: metrics.gridWidth, height: metrics.gridHeight, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }
}

struct FolderAppTile: View {
    @EnvironmentObject var model: LauncherModel
    let page: Int
    let group: AppGroup
    let app: AppItem
    let metrics: LaunchpadLayoutMetrics

    var body: some View {
        ZStack {
            AppIconCellContent(app: app, metrics: metrics)
                .contentShape(Rectangle())
                .onTapGesture {
                    model.activateFromPointer(.app(app))
                }
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.65, maximumDistance: 8)
                        .onEnded { _ in model.beginEditing() }
                )
                .onDrag {
                    model.startReorderDrag(app.id)
                    return LauncherDragProvider.make(for: .app(app))
                } preview: {
                    EntryDragPreview(icon: model.cachedIcon(for: app), iconSize: metrics.iconSize * 1.12)
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let sourceID = items.first else { return false }
                    guard model.openGroupID == group.id, page == model.folderPager.displayedPage else { return false }
                    return model.dropInOpenGroup(sourceID, beside: app.id, after: false)
                }
                .contextMenu {
                    if app.isDeletable {
                        Button(model.text("Delete Application…", "アプリケーションを削除…", "刪除應用程式…"), role: .destructive) {
                            model.requestDeleteApplication(app)
                        }
                    }
                    Button(model.text("Remove from Folder", "フォルダから取り出す", "從資料夾移出")) {
                        model.remove(app, from: group)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(app.name)
                .accessibilityHint(model.text(
                    "Opens the application",
                    "アプリケーションを開きます",
                    "開啟應用程式"
                ))
                .accessibilityAddTraits(model.highlightedEntryID == app.id ? [.isButton, .isSelected] : .isButton)

            if metrics.sideDropWidth > 1 {
                HStack(spacing: 0) {
                    sideDropZone(width: metrics.sideDropWidth, after: false)
                    Spacer(minLength: 0)
                    sideDropZone(width: metrics.sideDropWidth, after: true)
                }
            }
        }
        .frame(width: metrics.cellWidth, height: metrics.cellHeight)
        .modifier(LaunchpadTileDecoration(identifier: app.id, app: app, metrics: metrics))
    }

    private func sideDropZone(width: CGFloat, after: Bool) -> some View {
        Color.clear
            .frame(width: width)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                guard let sourceID = items.first else { return false }
                guard model.openGroupID == group.id, page == model.folderPager.displayedPage else { return false }
                return model.dropInOpenGroup(sourceID, beside: app.id, after: after)
            }
    }
}

/// Shared selection, edit feedback and the App Store delete badge. The
/// animation is local to a tile; Reduce Motion never starts a repeat cycle.
private struct LaunchpadTileDecoration: ViewModifier {
    @EnvironmentObject var model: LauncherModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var jiggle = false
    let identifier: String
    let app: AppItem?
    let metrics: LaunchpadLayoutMetrics

    private var animates: Bool { model.isEditing && !reduceMotion && model.isLauncherVisible }
    private var phase: Double { identifier.utf8.reduce(0) { $0 + Int($1) }.isMultiple(of: 2) ? 1 : -1 }

    func body(content: Content) -> some View {
        content
            .background(alignment: .top) {
                let highlightSize = metrics.iconSize * 0.8 + 10
                RoundedRectangle(cornerRadius: highlightSize * 0.24, style: .continuous)
                    .fill(Color.white.opacity(0.18))
                    .frame(width: highlightSize, height: highlightSize)
                    .offset(y: (metrics.iconSize - highlightSize) / 2)
                    .opacity(model.highlightedEntryID == identifier ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                if model.isEditing, let app, app.isDeletable {
                    Button {
                        model.requestDeleteApplication(app)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Color(white: 0.32), in: Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                            .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isDeleting)
                    .offset(x: (metrics.cellWidth - metrics.iconSize * 0.8) / 2 - 10,
                            y: metrics.iconSize * 0.1 - 10)
                    .accessibilityLabel(model.text("Delete \(app.name)", "\(app.name)を削除", "刪除 \(app.name)"))
                }
            }
            .rotationEffect(.degrees(animates ? (jiggle ? 1.15 : -1.15) * phase : 0))
            .onAppear { updateJiggle() }
            .onChange(of: animates) { _, _ in updateJiggle() }
    }

    private func updateJiggle() {
        if animates {
            withAnimation(.easeInOut(duration: 0.13).repeatForever(autoreverses: true)) { jiggle = true }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { jiggle = false }
        }
    }
}

struct LaunchpadBackground: View {
    @EnvironmentObject var model: LauncherModel
    let size: CGSize

    var body: some View {
        let width = max(1, size.width)
        let height = max(1, size.height)

        ZStack {
            Color(red: 0.10, green: 0.08, blue: 0.28)
                .frame(width: width + 8, height: height + 8)
            fallbackGradient
                .frame(width: width + 8, height: height + 8)
            Group {
                if (model.background.hasPrefix("file:") || model.background == "wallpaper"),
                   let image = model.selectedBackgroundImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: height)
                        .scaleEffect(1.08)
                        .blur(radius: 26)
                        .overlay(Color.black.opacity(0.25))
                } else if model.background == "light" {
                    Color(nsColor: .windowBackgroundColor)
                } else if model.background == "dark" {
                    Color(red: 0.04, green: 0.045, blue: 0.07)
                } else if model.background == "ocean" {
                    LinearGradient(
                        colors: [.blue, .cyan.opacity(0.6), .indigo],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                } else if model.background == "aurora" {
                    LinearGradient(
                        colors: [Color(red: 0.19, green: 0.08, blue: 0.35), .indigo, .teal.opacity(0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                } else {
                    fallbackGradient
                }
            }
        }
        .frame(width: width, height: height)
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var fallbackGradient: some View {
        LinearGradient(
            colors: [.indigo, .purple, .blue],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

enum LaunchpadSolidGlassStyle {
    case dark
    case light
}

extension View {
    @ViewBuilder
    func launchpadGlass<S: Shape>(
        in shape: S,
        interactive: Bool = false,
        tint: Color? = nil,
        reducesTransparency: Bool = false,
        solidStyle: LaunchpadSolidGlassStyle = .dark
    ) -> some View {
        if reducesTransparency {
            switch solidStyle {
            case .dark:
                background(Color.black.opacity(0.45), in: shape)
                    .overlay(shape.stroke(Color.white.opacity(0.32), lineWidth: 0.8))
            case .light:
                background(Color.white.opacity(0.85), in: shape)
                    .overlay(shape.stroke(Color.black.opacity(0.1), lineWidth: 0.8))
            }
        } else {
#if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                glassEffect(
                    .regular.tint(tint).interactive(interactive),
                    in: shape
                )
            } else {
                background(.ultraThinMaterial, in: shape)
                    .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 0.7))
            }
#else
            background(.ultraThinMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 0.7))
#endif
        }
    }
}
