import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 浮动面板控制器：NSPanel 无边框、置顶、不抢焦点。
/// Spike S4 目标：验证面板作为拖入目标 + 拖出源的双向拖放行为。
final class ShelfPanelController: NSObject {
    private var panel: NSPanel?
    /// 全局共享实例（崩溃修复：独立实例与设置页并发操作同一存储 → 悬垂崩溃）
    private let store = ShelfStore.shared
    private let settings: SettingsStore
    private let positionStore: PanelPositionStore
    private var panelOpacity: Double
    /// 程序化定位时置 true，抑制 didMove 反算持久化（只保存用户真实拖动结果）
    private var suppressPositionSave = false

    /// 条目数变化回调（菜单栏角标用，体验增强 3.4）
    var onItemCountChange: ((Int) -> Void)?

    /// 面板视图模型（V5-1 跳转访达：controller 需访问选中状态以响应 ⌘↩）
    private var panelModel: ShelfPanelModel?

    /// 键盘事件监听器（面板可见时生效，隐藏时移除）：Escape 关闭
    private var keyEventMonitor: Any?

    /// ⌘↩ 跳转访达的 Carbon 全局热键（面板可见时注册，隐藏时注销）。
    /// 用 Carbon 热键而非 local monitor 的原因（V5-1 全屏场景修复）：
    /// ⌘↩ 弹访达会激活 Finder → 本 app 失活 → local monitor 收不到后续事件；
    /// Carbon 全局热键不依赖 app active，Finder 激活后仍能响应 ⌘↩。
    private var revealHotKey: HotKeyManager?

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
        // accessory app 默认不接收键盘事件；激活后 Escape 监听才能生效
        //（ignoringOtherApps 不抢 Dock 焦点，与 Alfred/Spotlight 行为一致）
        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        // V3 修复：副屏全屏 app 下 Menu/NSAlert 无法弹出 —— 根因是 nonactivating
        // panel 未成为 key window，SwiftUI Menu 与 runModal 都依赖 key window。
        // activate 后显式 makeKey 让 panel 变 key（不激活 app，只接管键盘焦点），
        // 货架切换 Menu 与新建/重命名/删除弹窗才能正常弹出。
        panel.makeKey()
        // Escape 关闭（local monitor）
        startKeyMonitor()
        // ⌘↩ 跳转访达（Carbon 全局热键，面板可见时注册）
        startRevealHotKey()
    }

    func hide() {
        panel?.orderOut(nil)
        stopKeyMonitor()
        stopRevealHotKey()
    }

    /// 清空货架（体验缺陷 2.2）：超过设置阈值时确认；≤阈值直接清空；
    /// 阈值 = 0（始终确认）则每次都弹确认。
    /// 只移除引用，不删除源文件。
    func clearAllWithConfirmation() {
        Task { @MainActor in
            let count = await store.count
            guard count > 0 else { return }

            if SettingsStore.needsConfirmation(itemCount: count, threshold: settings.clearThreshold) {
                // Bug1 修复：nonactivating accessory app 的 runModal 确认框在未激活时
                // 可能无法弹出/异常 → 先激活（accessory 激活不会抢 Dock 焦点）
                NSApp.activate(ignoringOtherApps: true)
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

    // MARK: - 键盘监听（Escape 关闭 + ⌘↩ 跳转访达）

    /// 面板可见时启动 Escape 键监听；重复调用幂等（已有监听则跳过）。
    private func startKeyMonitor() {
        guard keyEventMonitor == nil else { return }
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // kVK_Escape = 53 → 关闭面板
            if event.keyCode == 53 {
                self.hide()
                return nil
            }
            return event
        }
    }

    /// 面板隐藏时移除 Escape 键监听；幂等。
    private func stopKeyMonitor() {
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }

    /// 面板可见时注册 ⌘↩ Carbon 全局热键（跳转访达）；幂等。
    private func startRevealHotKey() {
        guard revealHotKey == nil else { return }
        let hotKey = HotKeyManager(
            keyCode: HotKeyManager.keyCodeForReturn,
            modifiers: [.command],
            hotKeyID: 2
        )
        hotKey.onTrigger = { [weak self] in
            self?.revealSelectionInFinder()
        }
        do {
            try hotKey.register()
            revealHotKey = hotKey
        } catch {
            // ⌘↩ 被占用（罕见）→ 静默降级为不可用，不崩溃
            print("[ShelfPanel] ⌘↩ 热键注册失败: \(error)")
        }
    }

    /// 面板隐藏时注销 ⌘↩ 全局热键；幂等。
    private func stopRevealHotKey() {
        revealHotKey?.unregister()
        revealHotKey = nil
    }

    /// V5-1 跳转访达：仅单选（恰好选中 1 个）时，在 Finder 中定位并高亮显示该文件。
    /// 多选 / 无选中 → 忽略（决策 2：仅单选）。
    /// 注意：本方法由 ⌘↩ 的 Carbon 全局热键触发，不依赖本 app active，
    /// 因此 activateFileViewerSelecting 激活 Finder 后无需 reclaim（全屏场景也不再竞态）。
    private func revealSelectionInFinder() {
        let selected = panelModel?.selectedItems ?? []
        guard selected.count == 1, let item = selected.first, item.isReachable else { return }
        NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
    }

    /// 重新激活本 app + 面板变 key，让 local keyEventMonitor（Escape）持续收键盘事件。
    /// 触发源：从 Finder 拖文件进面板后，拖拽源 Finder 保持 active → 本 app 失活。
    /// 延迟 0.5s 等拖拽会话结束（拖放不切 Space，0.5s 足够）。
    private func reclaimKeyStatus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.panel?.makeKey()
        }
    }

    private func createPanel() {
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 204),
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

        let model = ShelfPanelModel(store: store)
        panelModel = model
        let content = NSHostingView(
            rootView: ShelfPanelView(
                model: model,
                onDismiss: { [weak self] in
                    self?.hide()
                },
                onReclaimKey: { [weak self] in
                    self?.reclaimKeyStatus()
                }
            ) { [weak self] count in
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
    @ObservedObject var model: ShelfPanelModel

    /// 面板关闭回调（header 关闭按钮 + Escape 键触发）
    var onDismiss: (() -> Void)?
    /// 拖放完成后重新激活回调（V5-1：从 Finder 拖文件后 reclaim key，保证键盘监听持续）
    var onReclaimKey: (() -> Void)?
    /// 面板宽度用于自适应布局（V2 固定 520，后续可调整）
    private let panelWidth: CGFloat = 520

    init(
        model: ShelfPanelModel,
        onDismiss: (() -> Void)? = nil,
        onReclaimKey: (() -> Void)? = nil,
        onItemsChange: ((Int) -> Void)? = nil
    ) {
        self.model = model
        self.model.onItemsChange = onItemsChange
        self.onDismiss = onDismiss
        self.onReclaimKey = onReclaimKey
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            content
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(width: 520, height: 204)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            model.addDroppedFiles(providers)
            // V5-1 修复：从 Finder 拖文件后，拖拽源 Finder 保持 active → 本 app 失活 →
            // 键盘监听失效。拖放完成后 reclaim key（延迟到拖拽会话结束）。
            onReclaimKey?()
            return true
        }
        // 注：空白点击清空选择不做 SwiftUI 手势（会干扰条目 overlay 点击，Bug3 教训）；
        // 如需空白清空，由面板背景 NSView 层处理（后续增强）。
    }

    /// 头部工具栏：货架切换 + 货架管理 + 条目数 + 清理失效 + 清空（V2-4）
    private var header: some View {
        HStack(spacing: 6) {
            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("关闭面板（Escape）")
            }
            shelfSwitcher
            shelfManagementMenu
            Spacer(minLength: 8)
            Text("\(model.items.count) 个文件")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
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
                    Image(systemName: "trash")
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
            HStack(spacing: 3) {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                Text("货架管理")
                    .font(.system(size: 11))
            }
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
            VStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(model.items) { item in
                            ShelfItemView(
                                item: item,
                                onMoveCompleted: { moved in
                                    model.removeItem(moved)
                                },
                                onClick: { modifier, clickedID in
                                    model.handleClick(clickedID, modifier: modifier)
                                },
                                isSelected: model.isSelected(item.id),
                                selectedItemIDs: model.selectedIDs,
                                selectedItems: model.selectedItems
                            )
                        }
                    }
                    .padding(10)
                }
                selectionHint
            }
        }
    }

    /// 多选快捷键提示（有条目时可见）
    private var selectionHint: some View {
        HStack {
            Spacer()
            HStack(spacing: 8) {
                if !model.selectedIDs.isEmpty {
                    Text("已选 \(model.selectedIDs.count) 个")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Text("⌘ 点击多选  ·  ⇧ 区间选择")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 2)
        }
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
        // Bug1 修复：nonactivating accessory app 的 runModal 需先激活
        NSApp.activate(ignoringOtherApps: true)
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
        // Bug1 修复：nonactivating accessory app 的 runModal 需先激活
        NSApp.activate(ignoringOtherApps: true)
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
    /// 多选状态（V2-6）：⌘ 切换 / Shift 区间 / 点击替换 / 空白清空
    @Published private(set) var selection = ShelfSelection()
    private let store: ShelfStore
    /// 条目数变化回调（菜单栏角标，体验增强 3.4）
    var onItemsChange: ((Int) -> Void)?
    private var clearAllObserver: NSObjectProtocol?

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

    // MARK: - 多选（V2-6）

    /// 当前选中条目 id 集合
    var selectedIDs: Set<UUID> { selection.ids }

    /// 当前选中条目（按货架顺序，批量拖出用）
    var selectedItems: [ShelfItem] {
        items.filter { selection.ids.contains($0.id) }
    }

    func isSelected(_ id: UUID) -> Bool {
        selection.ids.contains(id)
    }

    /// 点击条目选择（modifier 分类由拖拽视图层提供）
    func handleClick(_ id: UUID, modifier: SelectionModifier) {
        switch modifier {
        case .plain:
            selection.selectOnly(id)
        case .command:
            selection.toggle(id)
        case .shift:
            selection.shift(id, order: items.map(\.id))
        }
    }

    /// 点击空白取消选择
    func clearSelection() {
        selection.clear()
    }

    /// 批量移除选中（删除 / 拖出后同步选中集）
    func removeSelected(_ ids: Set<UUID>) {
        selection.remove(ids)
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

    func removeItem(_ item: ShelfItem) {
        Task {
            await store.remove(id: item.id)
            items = await store.all()
            selection.remove([item.id])
            notifyCount()
        }
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

/// 条目视图：图标 + 名称 + 大小 + 来源路径
/// 拖出（Spike S2）：不再用 `NSItemProvider(file URL)` 的复制语义。
/// SwiftUI `.onDrag` 无法承载 NSFilePromiseProvider（Apple 确认），故 overlay 一个
/// AppKit `FilePromiseDragView` 发起 promise 拖拽会话；Finder 兑现承诺时由
/// `FilePromiseDragManager` 执行真实 moveItem，实现"拖出 = 移动 + 货架移除"。
struct ShelfItemView: View {
    let item: ShelfItem
    /// 移动成功后的回调（通知货架移除该条目）
    var onMoveCompleted: (ShelfItem) -> Void
    /// 点击选择回调（⌘/⇧/plain 由视图层分类）
    var onClick: (SelectionModifier, UUID) -> Void
    /// 是否选中（高亮）
    var isSelected: Bool
    /// 选中条目集合（批量拖出用）
    var selectedItemIDs: Set<UUID>
    /// 选中条目（按货架顺序，批量拖出用）
    var selectedItems: [ShelfItem]

    @ViewBuilder
    var body: some View {
        if item.isReachable {
            content.overlay(
                FilePromiseDragRepresentable(
                    item: item,
                    onMoveCompleted: onMoveCompleted,
                    onClick: onClick,
                    selectedItemIDs: selectedItemIDs,
                    selectedItems: selectedItems
                )
            )
        } else {
            content.opacity(0.6)
        }
    }

    /// 条目图标三态（V3 文件夹支持）：
    /// - iCloud 占位 → `cloud` 灰色（不可达，不参与拖出）
    /// - 目录 → `folder.fill` 蓝色 tint（与文件明显区别）
    /// - 普通文件 → `doc` 默认色
    @ViewBuilder
    private var itemIcon: some View {
        if item.isCloudPlaceholder {
            Image(systemName: "cloud")
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
        } else if item.isDirectory {
            Image(systemName: "folder.fill")
                .font(.system(size: 20))
                .foregroundStyle(.tint)
        } else {
            Image(systemName: "doc")
                .font(.system(size: 20))
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                itemIcon
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
            isSelected
                ? Color.accentColor.opacity(0.30)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor.opacity(0.7) : Color.clear,
                    lineWidth: 1.5
                )
        )
    }
}
