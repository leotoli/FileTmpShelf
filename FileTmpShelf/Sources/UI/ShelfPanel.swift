import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 浮动面板控制器：NSPanel 无边框、置顶、不抢焦点。
/// Spike S4 目标：验证面板作为拖入目标 + 拖出源的双向拖放行为。
final class ShelfPanelController: NSObject {
    private var panel: NSPanel?
    private let store = ShelfStore()
    private let settings: SettingsStore
    private let positionStore: PanelPositionStore
    private var panelOpacity: Double
    /// 程序化定位时置 true，抑制 didMove 反算持久化（只保存用户真实拖动结果）
    private var suppressPositionSave = false

    /// 条目数变化回调（菜单栏角标用，体验增强 3.4）
    var onItemCountChange: ((Int) -> Void)?

    init(settings: SettingsStore = SettingsStore.shared, positionStore: PanelPositionStore = PanelPositionStore()) {
        self.settings = settings
        self.positionStore = positionStore
        self.panelOpacity = settings.panelOpacity
        super.init()
    }

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if panel == nil {
            createPanel()
        }
        guard let panel else { return }
        // V2-2 副屏唤醒：每次从隐藏→显示时按鼠标当前所在屏幕重新定位（相对锚点）
        if !panel.isVisible {
            placePanel(panel)
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// 清空货架（体验缺陷 2.2）：超过设置阈值时确认；≤阈值直接清空；
    /// 阈值 = 0（始终确认）则每次都弹确认。
    /// 只移除引用，不删除源文件。
    func clearAllWithConfirmation() {
        Task { @MainActor in
            let count = await store.count
            guard count > 0 else { return }

            if SettingsStore.needsConfirmation(itemCount: count, threshold: settings.clearThreshold) {
                let alert = NSAlert()
                alert.messageText = "确定清空货架？"
                alert.informativeText = "将移除 \(count) 个货架条目（仅移除引用，不会删除任何源文件）。"
                alert.addButton(withTitle: "清空")
                alert.addButton(withTitle: "取消")
                alert.alertStyle = .warning
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }

            await store.removeAll()
            onItemCountChange?(0)
        }
    }

    /// 应用面板透明度（设置滑块实时生效；面板未创建时记录，创建时应用）
    func applyOpacity(_ value: Double) {
        panelOpacity = value
        panel?.alphaValue = value
    }

    private func createPanel() {
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 188),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.level = .floating
        newPanel.isFloatingPanel = true
        newPanel.becomesKeyOnlyIfNeeded = true
        newPanel.isMovableByWindowBackground = true
        newPanel.hidesOnDeactivate = false
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        newPanel.alphaValue = panelOpacity

        let content = NSHostingView(
            rootView: ShelfPanelView(store: store) { [weak self] count in
                self?.onItemCountChange?(count)
            }
        )
        newPanel.contentView = content

        // 位置在 show() 时按鼠标所在屏计算；此处仅监听移动。
        // 用户拖动结束（didMove）反算「锚点+偏移」并持久化（V2-2 迁移到新模型）。
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: newPanel,
            queue: .main
        ) { [weak self, weak newPanel] _ in
            guard let self, let newPanel, !self.suppressPositionSave else { return }
            self.persistPosition(of: newPanel)
        }

        panel = newPanel
    }

    /// V2-2 定位：确定目标屏（鼠标所在屏，边界/无鼠标主屏兜底）→ resolvedFrame 决策
    /// （新模型锚点 / V1 旧绝对坐标 fallback / 默认锚点）。程序化 setFrame 期间抑制
    /// didMove 保存，避免把「唤醒定位」误当用户拖动写入。
    private func placePanel(_ panel: NSPanel) {
        let target = targetVisibleFrame()
        let frame = PanelPositioning.resolvedFrame(
            panelSize: panel.frame.size,
            targetVisibleFrame: target,
            storedPosition: positionStore.position,
            legacyFrame: positionStore.legacyFrame,
            screenFrames: NSScreen.screens.map(\.frame)
        )
        suppressPositionSave = true
        defer { suppressPositionSave = false }
        panel.setFrame(frame, display: false)
    }

    /// 目标屏幕可见帧：鼠标所在屏；无鼠标/不在任何屏 → 主屏兜底。
    private func targetVisibleFrame() -> NSRect {
        let screens = NSScreen.screens
        guard !screens.isEmpty else {
            return NSRect(x: 0, y: 0, width: 2000, height: 1200)
        }
        let fallbackIndex = screens.firstIndex { $0 === NSScreen.main } ?? 0
        let index = PanelPositioning.targetScreenIndex(
            mouseLocation: NSEvent.mouseLocation,
            screenFrames: screens.map(\.frame),
            fallbackIndex: fallbackIndex
        )
        return screens[index].visibleFrame
    }

    /// 拖动结束：按面板当前所在屏的可见帧反算锚点+偏移并持久化（迁移到新模型）。
    private func persistPosition(of panel: NSPanel) {
        let frame = panel.frame
        let center = NSPoint(x: frame.midX, y: frame.midY)
        let visible: NSRect
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            visible = screen.visibleFrame
        } else if let main = NSScreen.main {
            visible = main.visibleFrame
        } else {
            visible = frame
        }
        positionStore.save(from: frame, in: visible)
    }
}

/// 面板 SwiftUI 内容
struct ShelfPanelView: View {
    @StateObject private var model: ShelfPanelModel

    init(store: ShelfStore, onItemsChange: ((Int) -> Void)? = nil) {
        _model = StateObject(wrappedValue: ShelfPanelModel(store: store))
        _model.wrappedValue.onItemsChange = onItemsChange
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            content
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(width: 520, height: 188)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            model.addDroppedFiles(providers)
            return true
        }
        .contentShape(Rectangle())
        // 点击空白 → 取消选择（条目点击被 AppKit overlay 拦截，不会误触）
        .onTapGesture {
            model.clearSelection()
        }
    }

    /// 头部工具栏：货架切换 + 货架管理 + 条目数 + 多选操作 + 清理失效 + 清空（V2-4 / V2-6）
    private var header: some View {
        HStack(spacing: 6) {
            shelfSwitcher
            shelfManagementMenu
            Spacer(minLength: 8)
            Text("\(model.items.count) 个文件")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if !model.selectedIDs.isEmpty {
                Text("已选 \(model.selectedIDs.count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                Button {
                    model.pinSelection()
                } label: {
                    Image(systemName: "pin")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("置顶选中条目")
                Button {
                    Self.confirmAndDelete(ids: model.selectedIDs, model: model)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("删除选中条目（仅移除引用，不删除源文件）")
            }
            if model.hasUnreachable {
                Button {
                    model.clearUnreachable()
                } label: {
                    Image(systemName: "broom")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("清理失效条目")
            }
            if !model.items.isEmpty {
                Button {
                    model.clearAll()
                } label: {
                    Image(systemName: "xmark.bin")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("清空货架（仅移除引用，不删除源文件）")
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    /// 货架切换下拉：列出全部货架名称，点击切换当前货架
    private var shelfSwitcher: some View {
        Menu {
            ForEach(model.shelves) { shelf in
                Button {
                    model.selectShelf(id: shelf.id)
                } label: {
                    if shelf.id == model.selectedShelfID {
                        Label(shelf.name, systemImage: "checkmark")
                    } else {
                        Text(shelf.name)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "tray.full")
                    .font(.system(size: 10))
                Text(model.currentShelfName)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// 货架管理入口：新建 / 重命名 / 删除（删除最后一个禁用）
    private var shelfManagementMenu: some View {
        Menu {
            Button("新建货架…") { createShelf() }
            Button("重命名当前货架…") { renameShelf() }
            Divider()
            Button("删除当前货架…", role: .destructive) { deleteShelf() }
                .disabled(model.shelves.count <= 1)
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// 条目列表 / 空态
    @ViewBuilder
    private var content: some View {
        if model.items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "tray")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("拖文件到这里，或按 ⌥X 呼出")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(model.items) { item in
                        ShelfItemView(
                            item: item,
                            isSelected: model.selectedIDs.contains(item.id),
                            selectedIDs: model.selectedIDs,
                            selectedItems: model.selectedItems,
                            onClick: { modifier, id in
                                model.handleClick(modifier: modifier, id: id)
                            },
                            onMoveCompleted: { ids in
                                model.removeItems(ids: ids)
                            },
                            onPin: { ids in
                                model.pin(ids)
                            },
                            onDelete: { ids in
                                Self.confirmAndDelete(ids: ids, model: model)
                            }
                        )
                        .onDrag {
                            // 排序手柄（条目底部条带，未被 file-promise overlay 覆盖）
                            model.beginReorder(id: item.id)
                            return NSItemProvider(object: item.id.uuidString as NSString)
                        }
                    }
                }
                .padding(10)
                .onDrop(of: [.text], delegate: ReorderDropDelegate(
                    sourceID: { model.activeReorderSourceID },
                    itemCount: { model.items.count },
                    onMove: { id, target in model.reorder(moving: id, to: target) },
                    onCommit: { model.commitReorder() },
                    onExit: { model.cancelReorder() }
                ))
            }
        }
    }

    /// 删除选中（含确认）：>1 条或达到清空阈值时弹确认，只移除引用不删源文件。
    /// 右键菜单批量删除与头部"删除选中"共用。
    @MainActor
    private static func confirmAndDelete(ids: Set<UUID>, model: ShelfPanelModel) {
        guard !ids.isEmpty else { return }
        let needsConfirm = SettingsStore.needsConfirmation(
            itemCount: ids.count,
            threshold: SettingsStore.shared.clearThreshold
        )
        if needsConfirm {
            let alert = NSAlert()
            alert.messageText = "删除选中的 \(ids.count) 个条目？"
            alert.informativeText = "将移除选中的货架条目（仅移除引用，不会删除任何源文件）。"
            alert.addButton(withTitle: "删除")
            alert.addButton(withTitle: "取消")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        model.removeItems(ids: ids)
    }

    // MARK: - 货架管理操作（V2-4）

    private func createShelf() {
        guard let name = Self.promptText(
            title: "新建货架",
            message: "输入新货架名称：",
            defaultText: "新货架"
        ) else { return }
        model.createShelf(named: name)
    }

    private func renameShelf() {
        guard let name = Self.promptText(
            title: "重命名货架",
            message: "输入新的货架名称：",
            defaultText: model.currentShelfName
        ) else { return }
        model.renameCurrentShelf(to: name)
    }

    private func deleteShelf() {
        guard model.shelves.count > 1 else { return }
        let alert = NSAlert()
        alert.messageText = "删除货架「\(model.currentShelfName)」？"
        alert.informativeText = "将删除该货架及其 \(model.items.count) 个条目引用（仅移除引用，不会删除任何源文件）。"
        alert.addButton(withTitle: "删除")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.deleteCurrentShelf()
    }

    /// 文本输入弹窗（新建/重命名共用）：确定返回输入文本（空名视为取消），取消返回 nil
    @MainActor
    private static func promptText(title: String, message: String?, defaultText: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        if let message {
            alert.informativeText = message
        }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText
        alert.accessoryView = field
        alert.addButton(withTitle: "确定")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
}

/// 面板视图模型
final class ShelfPanelModel: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var shelves: [ShelfMeta] = []
    @Published private(set) var currentShelfName: String = ""
    @Published private(set) var selectedShelfID: UUID?
    /// 选中条目 id 集合（V2-6 多选）
    @Published private(set) var selectedIDs: Set<UUID> = []
    private let store: ShelfStore
    /// 条目数变化回调（菜单栏角标，体验增强 3.4）
    var onItemsChange: ((Int) -> Void)?
    private var clearAllObserver: NSObjectProtocol?
    /// 多选状态（纯逻辑，anchor 用于 Shift 区间）
    private var selection = ShelfSelection()
    /// 拖拽排序源条目 id（onDrag 发起，drop 过程中有效）
    var activeReorderSourceID: UUID? { reorderSourceID }
    private var reorderSourceID: UUID?
    private var originalOrderIDs: [UUID] = []

    init(store: ShelfStore) {
        self.store = store
        // 设置页「清除所有货架」后重载，保证面板与磁盘数据一致（V2-3）
        clearAllObserver = NotificationCenter.default.addObserver(
            forName: .shelfDidClearAll,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reload()
        }
        Task { await load() }
    }

    deinit {
        if let clearAllObserver {
            NotificationCenter.default.removeObserver(clearAllObserver)
        }
    }

    private func reload() {
        Task { await load() }
    }

    private func notifyCount() {
        onItemsChange?(items.count)
    }

    private func load() async {
        await store.load()
        await refresh()
    }

    /// 从 store 同步全部展示状态（货架列表 / 当前货架 / 条目数）
    private func refresh() async {
        shelves = await store.shelves()
        currentShelfName = await store.currentShelfName
        selectedShelfID = await store.currentShelf()?.id
        items = await store.all()
        // 货架切换 / 数据重载后清空选中，避免残留选中指向已不在当前货架的条目
        selection = ShelfSelection()
        selectedIDs = []
        notifyCount()
    }

    func addDroppedFiles(_ providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await loadFileURL(from: provider) {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            let outcome = await store.addBatch(urls)
            items = await store.all()
            notifyCount()
            print("[ShelfPanel] 挂载 \(urls.count) 个文件, 共 \(outcome.count) 条, 耗时 \(String(format: "%.3f", outcome.elapsed))s")
        }
    }

    // MARK: - 多选（V2-6）

    /// 当前选中的条目（按货架顺序）
    var selectedItems: [ShelfItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    /// 点击（选择）统一入口：AppKit overlay 与 SwiftUI 空条目点击都走这里
    func handleClick(modifier: SelectionModifier, id: UUID) {
        switch modifier {
        case .plain:
            selection.selectOnly(id)
        case .command:
            selection.toggle(id)
        case .shift:
            selection.shift(id, order: items.map(\.id))
        }
        selectedIDs = selection.ids
    }

    /// 点击面板空白 → 取消选择
    func clearSelection() {
        selection.clear()
        selectedIDs = []
    }

    /// 批量移除（删除选中 / 批量拖出），按 id 集合一次持久化
    func removeItems(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        selection.remove(ids)
        selectedIDs = selection.ids
        Task {
            await store.remove(ids: ids)
            items = await store.all()
            notifyCount()
        }
    }

    /// 置顶单个 / 一组条目（右键菜单或头部按钮），保持相对顺序
    func pin(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        Task {
            await store.pin(ids: ids)
            items = await store.all()
        }
    }

    func pinSelection() {
        pin(selectedIDs)
    }

    // MARK: - 拖拽排序（V2-6）

    /// onDrag 发起时记录源条目
    func beginReorder(id: UUID) {
        reorderSourceID = id
        originalOrderIDs = items.map(\.id)
    }

    /// drop 实时反馈：本地乐观重排（不写盘，drop 结束一次性提交）
    func reorder(moving id: UUID, to target: Int) {
        guard reorderSourceID == id else { return }
        let newItems = ReorderLogic.moving(items, id: id, to: target)
        guard newItems.map(\.id) != items.map(\.id) else { return }
        items = newItems
    }

    /// drop 结束：按最终顺序提交到 store（一次持久化）
    func commitReorder() {
        let order = items.map(\.id)
        reorderSourceID = nil
        originalOrderIDs = []
        Task {
            await store.reorder(by: order)
            items = await store.all()
        }
    }

    /// drop 移出面板：放弃本次排序，回滚到拖拽前顺序
    func cancelReorder() {
        guard reorderSourceID != nil else { return }
        let original = originalOrderIDs
        reorderSourceID = nil
        originalOrderIDs = []
        items = original.compactMap { id in items.first { $0.id == id } }
    }

    /// 是否存在失效条目（源文件已不可达）——决定是否显示"清理失效"按钮
    var hasUnreachable: Bool {
        items.contains { !$0.isReachable }
    }

    /// 清空当前货架（体验缺陷 2.2）：移除全部引用，不删除源文件
    func clearAll() {
        Task {
            await store.removeAll()
            items = await store.all()
            notifyCount()
        }
    }

    /// 清理失效条目（体验增强 3.2）：只移除不可达引用，无数据风险
    func clearUnreachable() {
        Task {
            await store.removeUnreachable()
            items = await store.all()
            notifyCount()
        }
    }

    // MARK: - 货架管理（V2-4）

    func selectShelf(id: UUID) {
        Task {
            await store.selectShelf(id: id)
            await refresh()
        }
    }

    func createShelf(named name: String) {
        Task {
            await store.createShelf(name: name)
            await refresh()
        }
    }

    func renameCurrentShelf(to name: String) {
        Task {
            guard let current = await store.currentShelf() else { return }
            await store.renameShelf(id: current.id, name: name)
            shelves = await store.shelves()
            currentShelfName = await store.currentShelfName
        }
    }

    func deleteCurrentShelf() {
        Task {
            guard let current = await store.currentShelf() else { return }
            await store.deleteShelf(id: current.id)
            await refresh()
        }
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data,
                   let parsed = URL(dataRepresentation: data, relativeTo: nil) {
                    url = parsed
                } else if let parsed = item as? URL {
                    url = parsed
                } else {
                    url = nil
                }
                continuation.resume(returning: url)
            }
        }
    }
}

/// 条目视图：图标 + 名称 + 大小 + 来源路径。
/// 拖出（Spike S2）：不再用 `NSItemProvider(file URL)` 的复制语义。
/// SwiftUI `.onDrag` 无法承载 NSFilePromiseProvider（Apple 确认），故 card 上 overlay 一个
/// AppKit `FilePromiseDragView` 发起 promise 拖拽会话；Finder 兑现承诺时由
/// `FilePromiseDragManager` 执行真实 moveItem，实现"拖出 = 移动 + 货架移除"。
/// V2-6：card 底部另有一条排序手柄（未被 overlay 覆盖），供 `.onDrag` 拖拽排序；
/// 选中态以高亮背景 + accent 描边呈现。
struct ShelfItemView: View {
    let item: ShelfItem
    var isSelected: Bool
    var selectedIDs: Set<UUID>
    var selectedItems: [ShelfItem]
    /// 点击（选择）回调
    var onClick: (SelectionModifier, UUID) -> Void
    /// 批量移除回调（多文件拖出 / 单个拖出统一按 id 集合）
    var onMoveCompleted: (Set<UUID>) -> Void
    var onPin: (Set<UUID>) -> Void
    var onDelete: (Set<UUID>) -> Void

    var body: some View {
        VStack(spacing: 3) {
            cardBody
                .opacity(item.isReachable ? 1.0 : 0.6)
                .overlay(
                    FilePromiseDragRepresentable(
                        item: item,
                        selectedIDs: selectedIDs,
                        selectedItems: selectedItems,
                        onClick: onClick,
                        onMoveCompleted: onMoveCompleted,
                        onPin: onPin,
                        onDelete: onDelete
                    )
                )
            reorderGrip
        }
        .frame(width: 150)
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: item.isCloudPlaceholder ? "cloud" : "doc")
                    .font(.system(size: 20))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(item.sourceParentPath)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if !item.isReachable {
                    Text("不可达")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(8)
        .frame(width: 150, height: 56)
        .background(
            isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.30))
                       : AnyShapeStyle(.regularMaterial),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
        )
    }

    /// 拖拽排序手柄：位于 card 下方，不被 file-promise overlay 覆盖，SwiftUI `.onDrag` 独占
    private var reorderGrip: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .frame(width: 40, height: 12)
            .contentShape(Rectangle())
    }
}

/// 面板内拖拽排序 drop 委托（横向布局）：按 drop 的 x 坐标换算目标槽位，
/// 实时乐观重排，drop 结束一次性提交 store，移出面板则回滚。
struct ReorderDropDelegate: DropDelegate {
    /// 当前拖拽源条目 id（无 active 拖拽时返回 nil）
    let sourceID: () -> UUID?
    let itemCount: () -> Int
    let onMove: (UUID, Int) -> Void
    let onCommit: () -> Void
    let onExit: () -> Void

    func validateDrop(info: DropInfo) -> Bool {
        // 仅响应我们自己的排序拖拽（有 active 源）；外部文本拖入直接拒绝
        sourceID() != nil
    }

    func dropEntered(info: DropInfo) {
        moveToDropPoint(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        moveToDropPoint(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        onExit()
    }

    func performDrop(info: DropInfo) -> Bool {
        onCommit()
        return true
    }

    private func moveToDropPoint(_ info: DropInfo) {
        guard let id = sourceID() else { return }
        let target = ReorderLogic.indexForX(
            info.location.x,
            count: itemCount()
        )
        onMove(id, target)
    }
}
