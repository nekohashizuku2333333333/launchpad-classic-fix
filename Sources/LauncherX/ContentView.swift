import SwiftUI
import AppKit

enum LaunchpadSearchFieldMetrics {
    static let topPadding = 80.0
    static let capsuleHeight = 34.0
    static var pagerTopOffset: Double { topPadding + capsuleHeight }
}

struct LauncherDisplayEntry: Identifiable {
    let id: String
    let entry: LauncherEntry?
}

struct FolderDisplayEntry: Identifiable {
    let id: String
    let app: AppItem?
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
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3),
            spacing: 3
        ) {
            ForEach(0..<min(9, max(1, icons.count)), id: \.self) { index in
                Image(nsImage: icons[index])
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .padding(8)
        .frame(width: size, height: size)
        .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: size * 0.22))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.22)
                .stroke(Color.white.opacity(0.3), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
    }
}

struct ContentView: View {
    @EnvironmentObject var model: LauncherModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var didRevealContent = false

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LaunchpadBackground(size: geometry.size)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
                    .ignoresSafeArea()
                Color.clear
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        if model.openGroupID != nil { model.closeFolder() } else { model.dismissLauncher() }
                    }
                ScrollWheelMonitor { model.navigateVisiblePages(by: $0) }
                VStack(spacing: 0) {
                    searchField.padding(.top, LaunchpadSearchFieldMetrics.topPadding)
                    PagedAppGrid()
                }
                .opacity(didRevealContent ? 1 : 0)
                .scaleEffect(didRevealContent ? 1 : (reduceMotion ? 1 : 1.04))
                .offset(y: didRevealContent ? 0 : (reduceMotion ? 0 : -12))
                .onAppear { revealContent() }
                .onChange(of: model.isLauncherVisible) { _, visible in
                    if visible {
                        revealContent()
                    } else {
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { didRevealContent = false }
                    }
                }
                if model.pageCount > 1 {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        LaunchpadPageIndicator(
                            pageCount: model.pageCount,
                            currentPage: min(model.currentPage, model.pageCount - 1),
                            onSelect: { model.goToPage($0) }
                        )
                        .padding(.bottom, 26)
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
            .onAppear { model.applyReferenceDefaultIconSize(pageWidth: geometry.size.width) }
            .onChange(of: geometry.size.width) { _, width in
                model.applyReferenceDefaultIconSize(pageWidth: width)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(!model.isDismissing)
        .foregroundStyle(model.background == "light" ? Color.black : Color.white)
        .confirmationDialog(model.text(
            "Delete this application?",
            "このアプリケーションを削除しますか？",
            "要刪除此應用程式嗎？"
        ),
            isPresented: Binding(get: { model.pendingDeleteApp != nil }, set: { if !$0 { model.pendingDeleteApp = nil } })) {
            Button(model.text("Move to Trash", "ゴミ箱に入れる", "移到垃圾桶"), role: .destructive) {
                model.deletePendingApplication()
            }
            Button(model.text("Cancel", "キャンセル", "取消"), role: .cancel) {
                model.pendingDeleteApp = nil
            }
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
            model.maximizeLauncherWindow()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            model.handleApplicationDidResignActive()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in
            model.handleApplicationDidHide()
        }
        .onExitCommand {
            if model.openGroupID != nil { model.closeFolder() } else { model.dismissLauncher() }
        }
    }

    private func revealContent() {
        guard !didRevealContent else { return }
        withAnimation(.easeOut(duration: 0.35)) { didRevealContent = true }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").foregroundStyle(searchSymbolColor)
            TextField(
                model.text("Search", "検索", "搜尋"),
                text: $model.search,
                prompt: searchPrompt
            )
            .textFieldStyle(.plain).frame(width: 210)
            if !model.search.isEmpty {
                Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(searchSymbolColor)
                    .accessibilityLabel(model.text("Clear Search", "検索を消去", "清除搜尋"))
            }
            LauncherSettingsMenu()
        }
        .padding(.leading, 12).padding(.trailing, 6).frame(height: LaunchpadSearchFieldMetrics.capsuleHeight)
        .launchpadGlass(
            in: Capsule(),
            interactive: true,
            reducesTransparency: model.reducesTransparency,
            solidStyle: usesLightSearchContent ? .light : .dark
        )
    }

    private var usesLightSearchContent: Bool { model.background == "light" }

    private var searchSymbolColor: Color {
        guard !usesLightSearchContent, model.reducesTransparency else { return .secondary }
        return .white.opacity(0.72)
    }

    private var searchPrompt: Text? {
        guard !usesLightSearchContent, model.reducesTransparency else { return nil }
        return Text(model.text("Search", "検索", "搜尋"))
            .foregroundColor(.white.opacity(0.55))
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
                preferredIconSize: model.iconSize
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

/// Geometry of a classic Launchpad inline folder expansion: the page splits
/// at the folder's row, rows above move up, rows below move down, and the
/// folder content occupies the gap between them.
struct FolderSplitState: Equatable {
    let group: AppGroup
    let folderApps: [AppItem]
    let row: Int
    let contentMetrics: LaunchpadLayoutMetrics
    let pageCount: Int
    let bandWidth: CGFloat
    let bandHeight: CGFloat
    let bandCenterY: CGFloat
    let upwardDisplacement: CGFloat
    let downwardDisplacement: CGFloat

    var folderEntryID: String { "group:" + group.id.uuidString }
}

enum FolderBandMetrics {
    static let verticalPadding = 16.0
    static let horizontalPadding = 20.0
    static let titleHeight = 30.0
    static let titleSpacing = 10.0
    static let indicatorHeight = 26.0
    static let indicatorSpacing = 10.0
    static let cornerRadius = 28.0
    static let minimumEdgeInset = 12.0
    static let minimumBandWidth = 360.0

    static func chromeHeight(includesIndicator: Bool) -> Double {
        verticalPadding * 2 + titleHeight + titleSpacing
            + (includesIndicator ? indicatorHeight + indicatorSpacing : 0)
    }

    static func bandWidth(
        folderGridWidth: Double,
        canvasWidth: Double,
        sideMargin: Double
    ) -> Double {
        let usable = max(minimumBandWidth, canvasWidth - sideMargin * 2)
        return min(usable, max(folderGridWidth + horizontalPadding * 2 + 32, usable * 0.56))
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

    var body: some View {
        GeometryReader { pagerGeometry in
            let pageWidth = max(1, pagerGeometry.size.width)
            let pageHeight = max(1, pagerGeometry.size.height)
            let activePage = min(model.displayedPage, pageCount - 1)
            let split = folderSplitState(
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
                            if model.openGroupID == nil { model.dismissLauncher() }
                        }
                    )
                    .dropDestination(for: String.self) { items, _ in
                        guard model.openGroupID == nil else { return false }
                        guard let sourceID = items.first else { return false }
                        if let preview = model.reorderPreview, model.openGroupID == nil {
                            model.reorderToSlot(
                                sourceID,
                                page: preview.page,
                                slot: preview.slot,
                                pageSize: pageSize
                            )
                        } else {
                            model.reorderToPageEnd(sourceID, page: activePage, pageSize: pageSize)
                        }
                        return true
                    }

                ForEach(
                    LaunchpadPageMotion.visiblePages(
                        currentPage: model.displayedPage,
                        pageCount: pageCount
                    ),
                    id: \.self
                ) { page in
                    let pageSplit = page == activePage ? split : nil
                    RootPageRows(
                        displayEntries: displayEntries(on: page),
                        metrics: metrics,
                        split: pageSplit,
                        pageWidth: pageWidth
                    )
                    .offset(
                        x: CGFloat(page - activePage) * pageWidth
                            + dragOffset
                    )
                    .allowsHitTesting(page == model.displayedPage && split == nil && model.openGroupID == nil)
                    .compositingGroup()
                }

                if let split {
                    FolderSplitLayer(
                        split: split,
                        canvasWidth: pageWidth,
                        canvasHeight: pageHeight
                    )
                    .transition(.opacity)
                    .zIndex(10)
                }
            }
            .clipped()
            .opacity(model.reducedMotionPageHidden ? 0 : 1)
            .onAppear { reportLayout(size: pagerGeometry.size) }
            .onChange(of: pagerGeometry.size) { _, size in reportLayout(size: size) }
            .onChange(of: metrics) { _, _ in reportLayout(size: pagerGeometry.size) }
            .onChange(of: pageSize) { _, _ in reportLayout(size: pagerGeometry.size) }
        }
    }

    private func reportLayout(size: CGSize) {
        model.updateRootPagerLayout(
            topOffset: LaunchpadSearchFieldMetrics.pagerTopOffset,
            size: size,
            metrics: metrics,
            pageSize: pageSize
        )
    }

    private func folderSplitState(
        pageWidth: CGFloat,
        pageHeight: CGFloat,
        activePage: Int
    ) -> FolderSplitState? {
        guard model.search.isEmpty,
              let group = model.group(for: model.openGroupID) else { return nil }
        let folderID = "group:" + group.id.uuidString
        guard let index = allEntries.firstIndex(where: { $0.id == folderID }),
              index / pageSize == activePage else { return nil }

        let folderRow = (index % pageSize) / metrics.columns
        let folderApps = model.apps(in: group)
        let itemCount = folderApps.count
        let available = pageHeight - LaunchpadLayoutMetrics.bottomReserve
        var rowLimit = min(
            LaunchpadLayoutMetrics.folderMaximumRows,
            metrics.rowsFitting(
                availableHeight: available - FolderBandMetrics.chromeHeight(includesIndicator: false)
            )
        )
        var content = LaunchpadLayoutMetrics.folderContent(
            base: metrics,
            itemCount: itemCount,
            rowLimit: rowLimit
        )
        var folderPageCount = content.pageCount(forItemCount: itemCount)
        if folderPageCount > 1 {
            rowLimit = min(
                LaunchpadLayoutMetrics.folderMaximumRows,
                metrics.rowsFitting(
                    availableHeight: available - FolderBandMetrics.chromeHeight(includesIndicator: true)
                )
            )
            content = LaunchpadLayoutMetrics.folderContent(
                base: metrics,
                itemCount: itemCount,
                rowLimit: rowLimit
            )
            folderPageCount = content.pageCount(forItemCount: itemCount)
        }

        let bandHeight = FolderBandMetrics.chromeHeight(includesIndicator: folderPageCount > 1)
            + content.gridHeight
        let sideMargin = LaunchpadLayoutMetrics.sideMargin(forContainerWidth: pageWidth)
        let bandWidth = FolderBandMetrics.bandWidth(
            folderGridWidth: content.gridWidth,
            canvasWidth: pageWidth,
            sideMargin: sideMargin
        )
        let folderRowTop = metrics.topInset + CGFloat(folderRow) * metrics.rowStride
        let rowCenterY = folderRowTop + metrics.cellHeight / 2
        let minimumY = FolderBandMetrics.minimumEdgeInset
        let maximumY = max(
            minimumY,
            pageHeight - LaunchpadLayoutMetrics.bottomReserve - bandHeight
        )
        let bandMinY = min(max(rowCenterY - bandHeight / 2, minimumY), maximumY)
        // Rows must clear the band's final (clamped) position on both sides.
        let bandClearance: CGFloat = 10
        let rowAboveBottom = folderRowTop - metrics.verticalSpacing
        let upward = max(0, rowAboveBottom - (bandMinY - bandClearance))
        let downward = max(0, (bandMinY + bandHeight + bandClearance) - folderRowTop)

        return FolderSplitState(
            group: group,
            folderApps: folderApps,
            row: folderRow,
            contentMetrics: content,
            pageCount: folderPageCount,
            bandWidth: bandWidth,
            bandHeight: bandHeight,
            bandCenterY: bandMinY + bandHeight / 2,
            upwardDisplacement: upward,
            downwardDisplacement: downward
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
        return result
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
                dragOffset = min(max(horizontal * resistance, -limit), limit)
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

/// One page of the root grid, rendered as fixed-width rows so the page can
/// split apart at a folder row while keeping every column aligned.
struct RootPageRows: View {
    @EnvironmentObject var model: LauncherModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let displayEntries: [LauncherDisplayEntry]
    let metrics: LaunchpadLayoutMetrics
    let split: FolderSplitState?
    let pageWidth: CGFloat

    private var rows: [[LauncherDisplayEntry]] {
        stride(from: 0, to: displayEntries.count, by: metrics.columns).map { start in
            Array(displayEntries[start..<min(start + metrics.columns, displayEntries.count)])
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, rowEntries in
                HStack(spacing: metrics.horizontalSpacing) {
                    ForEach(rowEntries) { display in
                        if let entry = display.entry {
                            AppCell(
                                entry: entry,
                                metrics: metrics,
                                isHidden: entry.id == split?.folderEntryID
                            )
                        } else {
                            Color.clear
                                .frame(width: metrics.cellWidth, height: metrics.cellHeight)
                        }
                    }
                }
                .frame(width: metrics.gridWidth, height: metrics.cellHeight, alignment: .leading)
                .offset(x: (pageWidth - metrics.gridWidth) / 2, y: rowYOffset(rowIndex))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(
            reduceMotion
                ? .easeInOut(duration: 0.2)
                : .spring(response: 0.4, dampingFraction: 0.88),
            value: split
        )
        .animation(
            reduceMotion ? .easeInOut(duration: 0.18) : .easeInOut(duration: 0.24),
            value: displayEntries.map(\.id)
        )
        .animation(
            reduceMotion
                ? .easeInOut(duration: 0.18)
                : .spring(response: 0.3, dampingFraction: 0.85),
            value: model.reorderPreview
        )
        .animation(
            reduceMotion
                ? .easeInOut(duration: 0.18)
                : .spring(response: 0.3, dampingFraction: 0.85),
            value: model.reorderDragSourceID
        )
    }

    private func rowYOffset(_ rowIndex: Int) -> CGFloat {
        let base = metrics.topInset + CGFloat(rowIndex) * metrics.rowStride
        guard let split else { return base }
        return rowIndex < split.row
            ? base - split.upwardDisplacement
            : base + split.downwardDisplacement
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
                            width: page == currentPage ? 10 : 8,
                            height: page == currentPage ? 10 : 8
                        )
                        .shadow(color: .black.opacity(0.38), radius: 1.5, y: 1)
                }
                .frame(width: 24, height: 26)
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
        .padding(.horizontal, 7)
        .frame(height: 26)
        .launchpadGlass(
            in: Capsule(),
            interactive: true,
            reducesTransparency: model.reducesTransparency
        )
        .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
        .animation(reduceMotion ? nil : LaunchpadPageMotion.animation(), value: currentPage)
    }
}

/// Unified grid cell (icon + label) with fixed layout bounds. Apps and
/// folders occupy identical cells so their columns, label baselines and
/// drag hitboxes always align.
struct AppCell: View {
    @EnvironmentObject var model: LauncherModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let entry: LauncherEntry
    let metrics: LaunchpadLayoutMetrics
    var isHidden = false

    var body: some View {
        ZStack {
            centerContent
                .contentShape(Rectangle())
                .onTapGesture {
                    switch entry {
                    case .app(let app): model.launch(app)
                    case .group(let group): model.open(group)
                    }
                }
                .onDrag {
                    model.startReorderDrag(entry.id)
                    return NSItemProvider(object: entry.id as NSString)
                } preview: {
                    dragPreview
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let sourceID = items.first else { return false }
                    guard model.openGroupID == nil else { return false }
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
                            model.pendingDeleteApp = app
                        }
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(accessibilityHint)
                .accessibilityAddTraits(.isButton)

            if metrics.sideDropWidth > 1 {
                HStack(spacing: 0) {
                    sideDropZone(width: metrics.sideDropWidth, after: false)
                    Spacer(minLength: 0)
                    sideDropZone(width: metrics.sideDropWidth, after: true)
                }
            }
        }
        .frame(width: metrics.cellWidth, height: metrics.cellHeight)
        .opacity(isHidden ? 0 : 1)
        .scaleEffect(isHidden ? 1.3 : 1)
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
            .font(.system(size: LaunchpadLayoutMetrics.labelFontSize, weight: .medium))
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
                guard model.openGroupID == nil else { return false }
                model.reorder(sourceID, beside: entry.id, after: after)
                return true
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
                .shadow(color: .black.opacity(0.32), radius: 7, y: 4)
            Text(app.name)
                .font(.system(size: LaunchpadLayoutMetrics.labelFontSize, weight: .medium))
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
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3),
            spacing: 3
        ) {
            ForEach(preview) { app in
                ApplicationArtwork(app: app, size: max(12, (size - 22) / 3))
            }
        }
        .padding(8)
        .frame(width: size, height: size)
        .launchpadGlass(
            in: RoundedRectangle(cornerRadius: size * 0.22),
            interactive: true,
            reducesTransparency: model.reducesTransparency
        )
        .shadow(color: .black.opacity(0.3), radius: 7, y: 4)
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

/// Classic inline folder expansion: a full-canvas catcher closes the folder
/// (and accepts drops that move an app out of it), while the expanded
/// content sits in the gap the page opened at the folder's row. It belongs
/// to the same Launchpad page visually — no separate floating window.
struct FolderSplitLayer: View {
    @EnvironmentObject var model: LauncherModel
    let split: FolderSplitState
    let canvasWidth: CGFloat
    let canvasHeight: CGFloat

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { model.closeFolder() }
            .dropDestination(for: String.self) { items, _ in
                guard let sourceID = items.first else { return false }
                model.moveOutOfOpenGroup(sourceID)
                return true
            }

        FolderExpandedBand(split: split, canvasWidth: canvasWidth, canvasHeight: canvasHeight)
            .position(x: canvasWidth / 2, y: split.bandCenterY)
    }
}

struct FolderExpandedBand: View {
    @EnvironmentObject var model: LauncherModel
    @EnvironmentObject var folderPager: FolderPagerState
    let split: FolderSplitState
    let canvasWidth: CGFloat
    let canvasHeight: CGFloat

    var body: some View {
        VStack(spacing: FolderBandMetrics.titleSpacing) {
            FolderTitleEditor(groupID: split.group.id, initialName: split.group.name)
                .frame(height: FolderBandMetrics.titleHeight)

            FolderPagerCanvas(
                group: split.group,
                folderApps: split.folderApps,
                capacity: split.contentMetrics.capacity,
                pageCount: split.pageCount,
                metrics: split.contentMetrics,
                pageWidth: split.bandWidth - FolderBandMetrics.horizontalPadding * 2
            )
            .frame(height: split.contentMetrics.gridHeight)
            .clipped()

            if split.pageCount > 1 {
                LaunchpadPageIndicator(
                    pageCount: split.pageCount,
                    currentPage: min(folderPager.page, split.pageCount - 1),
                    onSelect: { model.goToFolderPage($0) }
                )
                .frame(height: FolderBandMetrics.indicatorHeight)
            }
        }
        .padding(.horizontal, FolderBandMetrics.horizontalPadding)
        .padding(.vertical, FolderBandMetrics.verticalPadding)
        .frame(width: split.bandWidth, height: split.bandHeight)
        .background(bandBackdrop)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let sourceID = items.first else { return false }
            model.addToOpenGroup(sourceID)
            return true
        }
        .onAppear {
            model.setFolderPageCount(split.pageCount)
            reportFolderLayout()
        }
        .onChange(of: split.pageCount) { _, count in model.setFolderPageCount(count) }
        .onChange(of: split) { _, _ in reportFolderLayout() }
    }

    /// A quiet translucent wash that reads as part of the page rather than a
    /// standalone floating card.
    private var bandBackdrop: some View {
        let shape = RoundedRectangle(cornerRadius: FolderBandMetrics.cornerRadius, style: .continuous)
        return ZStack {
            if usesStaticBackdrop {
                shape.fill(Color.black.opacity(0.48))
            } else {
                shape.fill(.ultraThinMaterial)
                shape.fill(Color.black.opacity(0.16))
            }
        }
        .overlay(shape.stroke(Color.white.opacity(0.1), lineWidth: 0.8))
        .shadow(
            color: .black.opacity(usesStaticBackdrop ? 0.14 : 0.2),
            radius: usesStaticBackdrop ? 8 : 16,
            y: usesStaticBackdrop ? 3 : 5
        )
    }

    private var usesStaticBackdrop: Bool {
        model.reducesTransparency || split.pageCount > 1
    }

    private func reportFolderLayout() {
        let bandMinY = split.bandCenterY - split.bandHeight / 2
        let gridOriginX = (canvasWidth - split.contentMetrics.gridWidth) / 2
        let gridOriginY = LaunchpadSearchFieldMetrics.pagerTopOffset
            + bandMinY + FolderBandMetrics.verticalPadding
            + FolderBandMetrics.titleHeight + FolderBandMetrics.titleSpacing
        model.updateFolderPagerLayout(
            origin: CGPoint(x: gridOriginX, y: gridOriginY),
            cellWidth: split.contentMetrics.cellWidth,
            columnCount: split.contentMetrics.columns,
            capacity: split.contentMetrics.capacity,
            columnSpacing: split.contentMetrics.horizontalSpacing,
            rowSpacing: split.contentMetrics.verticalSpacing,
            itemHeight: split.contentMetrics.cellHeight
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
            .font(.system(size: 20, weight: .semibold))
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
                        .font(.system(size: 20, weight: .semibold))
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                    Image(systemName: "pencil.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
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

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(
                .fixed(metrics.cellWidth),
                spacing: metrics.horizontalSpacing
            ),
            count: metrics.columns
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(Rectangle())
                .gesture(pageDragGesture)
                .dropDestination(for: String.self) { items, _ in
                    guard let sourceID = items.first else { return false }
                    if let preview = model.reorderPreview, model.openGroupID != nil {
                        model.reorderInOpenGroupToSlot(
                            sourceID,
                            slot: preview.slot,
                            capacity: capacity
                        )
                    } else {
                        model.reorderInOpenGroupToPageEnd(
                            sourceID,
                            page: min(folderPager.page, pageCount - 1),
                            capacity: capacity
                        )
                    }
                    return true
                }

            ForEach(
                LaunchpadPageMotion.visiblePages(
                    currentPage: folderPager.displayedPage,
                    pageCount: pageCount
                ),
                id: \.self
            ) { page in
                FolderAppGrid(
                    group: group,
                    displayApps: displayApps(on: page),
                    columns: columns,
                    metrics: metrics
                )
                .frame(maxWidth: .infinity, alignment: .top)
                .offset(
                    x: CGFloat(page - min(folderPager.displayedPage, pageCount - 1)) * pageWidth
                        + dragOffset
                )
                .allowsHitTesting(page == folderPager.displayedPage)
                .compositingGroup()
            }
        }
        .opacity(folderPager.reducedMotionPageHidden ? 0 : 1)
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
                dragOffset = min(max(horizontal * resistance, -limit), limit)
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
    @EnvironmentObject var model: LauncherModel
    let group: AppGroup
    let displayApps: [FolderDisplayEntry]
    let columns: [GridItem]
    let metrics: LaunchpadLayoutMetrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: metrics.verticalSpacing) {
            ForEach(displayApps) { display in
                if let app = display.app {
                    FolderAppTile(group: group, app: app, metrics: metrics)
                } else {
                    Color.clear
                        .frame(width: metrics.cellWidth, height: metrics.cellHeight)
                }
            }
        }
        .animation(
            reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.3, dampingFraction: 0.85),
            value: model.reorderPreview
        )
        .animation(
            reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.3, dampingFraction: 0.85),
            value: model.reorderDragSourceID
        )
        .frame(width: metrics.gridWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }
}

struct FolderAppTile: View {
    @EnvironmentObject var model: LauncherModel
    let group: AppGroup
    let app: AppItem
    let metrics: LaunchpadLayoutMetrics

    var body: some View {
        ZStack {
            AppIconCellContent(app: app, metrics: metrics)
                .contentShape(Rectangle())
                .onTapGesture { model.launch(app) }
                .onDrag {
                    model.startReorderDrag(app.id)
                    return NSItemProvider(object: app.id as NSString)
                } preview: {
                    EntryDragPreview(icon: model.cachedIcon(for: app), iconSize: metrics.iconSize * 1.12)
                }
                .dropDestination(for: String.self) { items, _ in
                    guard let sourceID = items.first else { return false }
                    model.reorderInOpenGroup(sourceID, beside: app.id, after: false)
                    return true
                }
                .contextMenu {
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
                .accessibilityAddTraits(.isButton)

            if metrics.sideDropWidth > 1 {
                HStack(spacing: 0) {
                    sideDropZone(width: metrics.sideDropWidth, after: false)
                    Spacer(minLength: 0)
                    sideDropZone(width: metrics.sideDropWidth, after: true)
                }
            }
        }
        .frame(width: metrics.cellWidth, height: metrics.cellHeight)
    }

    private func sideDropZone(width: CGFloat, after: Bool) -> some View {
        Color.clear
            .frame(width: width)
            .contentShape(Rectangle())
            .dropDestination(for: String.self) { items, _ in
                guard let sourceID = items.first else { return false }
                model.reorderInOpenGroup(sourceID, beside: app.id, after: after)
                return true
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
