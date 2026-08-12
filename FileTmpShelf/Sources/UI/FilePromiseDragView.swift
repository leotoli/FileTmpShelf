import AppKit
import SwiftUI

/// Spike S2：file promise 拖出发起视图。V2-6 扩展：多选点击 / 批量多文件拖出 / 右键菜单。
///
/// SwiftUI 的 `.onDrag` 只能返回 `NSItemProvider`，而 file promise 需要
/// `NSFilePromiseProvider`（二者都符合 NSPasteboardWriting 但无继承关系），
/// Apple 已确认 `.onDrag` 无法直接承载 file promise。因此拖拽发起走 AppKit：
/// 本视图以 overlay 形式盖在条目内容上，`mouseDown` 记录起点，`mouseDragged`
/// 超过阈值（10pt）后用 `NSDraggingItem(pasteboardWriter: promise)` 发起拖拽会话。
///
/// V2-6 多文件拖出：被拖条目在选中集中且有多选时，为**每个**选中文件生成独立的
/// `FilePromiseDragManager` + `CombinedFilePromiseProvider` + `NSDraggingItem`
/// （每个 promise 都有自己的 delegate/manager，Finder 兑现时逐个回调）；
/// 拖拽 frame 叠加小幅错位（fan-out）展示多文件。`onMoveCompleted` 对每个
/// manager 回调时按整批 id 移除（`ShelfStore.remove(ids:)` 幂等去重）。
///
/// 视图随 SwiftUI 条目生命周期存活，天然强持有 `FilePromiseDragManager`，
/// 解决 NSFilePromiseProvider.delegate 是 weak、而 Finder 兑现承诺（拖放结束后
/// 异步回调）需要 delegate 存活的问题。
final class FilePromiseDragView: NSView {
    var item: ShelfItem? {
        didSet { updateInteractions() }
    }
    /// 当前选中集合（决定批量拖出集合 / 右键菜单"删除选中"）
    var selectedItemIDs: Set<UUID> = [] {
        didSet { updateInteractions() }
    }
    /// 当前选中的条目（批量拖出用，按货架顺序）
    var selectedItems: [ShelfItem] = [] {
        didSet { updateInteractions() }
    }
    /// 点击（选择）回调：modifier 分类 + 条目 id
    var onClick: ((SelectionModifier, UUID) -> Void)? {
        didSet { updateInteractions() }
    }
    /// 批量移除回调（Finder 兑现 promise / 非 promise 目标交付后按 id 集合移除）
    var onMoveCompleted: ((Set<UUID>) -> Void)? {
        didSet { updateInteractions() }
    }
    /// 右键菜单"置顶"回调
    var onPin: ((Set<UUID>) -> Void)? {
        didSet { updateInteractions() }
    }
    /// 右键菜单"删除"回调（UI 层负责批量确认）
    var onDelete: ((Set<UUID>) -> Void)? {
        didSet { updateInteractions() }
    }

    /// 当前拖拽会话的 manager 列表；provider.delegate 是 weak，需随本视图生命周期强持有
    private var activeManagers: [FilePromiseDragManager] = []
    private var mouseDownLocation: CGPoint = .zero
    private var hasDraggingSession = false
    /// 右键菜单待执行动作的条目集合
    private var pendingActionIDs: Set<UUID> = []

    /// 是否有正在进行的文件拖拽会话（全局；V2-7 空格预览在拖拽中不触发，
    /// 避免拖出文件时误开 Quick Look）。拖拽开始置 true，会话结束置 false。
    private(set) static var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        updateInteractions()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        updateInteractions()
    }

    /// 空视图需要明确 hit-test 命中自身，否则 mouseDown/mouseDragged 收不到事件
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    /// 面板是 nonactivating panel：首次按下即拖拽也应收发事件，无需先激活 app
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    /// 关键（体验缺陷 2.1 修复）：鼠标落在条目区域拖动时，事件应只用于发起文件拖拽，
    /// 不允许窗口解释为"移动窗口"。面板移动保留给空白区域（isMovableByWindowBackground）。
    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
        // 拖拽反馈（3.1）：按下即轻微压暗，拖拽会话结束后恢复
        alphaValue = 0.85
    }

    override func mouseUp(with event: NSEvent) {
        guard !hasDraggingSession else { return }
        alphaValue = 1.0
        guard let item else { return }
        // 未拖动 = 点击 → 选择（Finder 语义：⌘ 切换 / Shift 区间 / 无修饰键单选）
        let flags = event.modifierFlags
        if flags.contains(.shift) {
            onClick?(.shift, item.id)
        } else if flags.contains(.command) {
            onClick?(.command, item.id)
        } else {
            onClick?(.plain, item.id)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !hasDraggingSession else { return }
        guard let item, item.isReachable else { return }

        let distance = hypot(
            event.locationInWindow.x - mouseDownLocation.x,
            event.locationInWindow.y - mouseDownLocation.y
        )
        // 位移阈值：区分"点击/滚动"与"拖拽"，与 Finder 条目手感一致
        guard distance > 10 else { return }

        // V2-6 批量拖出：被拖条目在选中集中且多选 → 拖出整个选中集；否则仅拖出自身
        var dragTargets: [ShelfItem]
        if selectedItemIDs.contains(item.id), selectedItems.count > 1 {
            dragTargets = selectedItems
        } else {
            dragTargets = [item]
        }
        dragTargets = dragTargets.filter { $0.isReachable }
        guard !dragTargets.isEmpty else { return }

        var managers: [FilePromiseDragManager] = []
        var draggingItems: [NSDraggingItem] = []
        let dragIDs = Set(dragTargets.map(\.id))
        for (index, target) in dragTargets.enumerated() {
            // 每个 promise 一个 manager；Finder 兑现（writePromiseToURL 成功）时
            // 按整批 id 移除货架条目（幂等：remove(ids:) 按 id 去重，重复调用无害）
            let manager = FilePromiseDragManager(item: target) { [weak self] _ in
                self?.onMoveCompleted?(dragIDs)
            }
            managers.append(manager)

            let promise = CombinedFilePromiseProvider(
                fileType: FilePromiseDragManager.promiseFileType(for: target),
                delegate: manager,
                fileURL: target.fileURL
            )
            let draggingItem = NSDraggingItem(pasteboardWriter: promise)
            // 多文件拖拽 frame 轻微错位（fan-out），展示"多个文件"而非重叠成一个
            var dragFrame = NSRect(origin: .zero, size: frame.size)
            dragFrame.origin.x += CGFloat(index) * 14
            dragFrame.origin.y -= CGFloat(index) * 8
            draggingItem.setDraggingFrame(dragFrame, contents: snapshotImage())
            draggingItems.append(draggingItem)
        }
        activeManagers = managers
        Self.isDragging = true
        beginDraggingSession(with: draggingItems, event: event, source: self)
        hasDraggingSession = true
    }

    // MARK: - 右键菜单（V2-6 置顶 / 删除）

    override func rightMouseDown(with event: NSEvent) {
        guard let item, onPin != nil || onDelete != nil else { return }
        let isMulti = selectedItemIDs.contains(item.id) && selectedItemIDs.count > 1
        pendingActionIDs = isMulti ? selectedItemIDs : [item.id]

        let menu = NSMenu()
        if isMulti {
            menu.addItem(withTitle: "置顶选中（\(selectedItemIDs.count) 项）", action: #selector(menuPin(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "删除选中（\(selectedItemIDs.count) 项）", action: #selector(menuDelete(_:)), keyEquivalent: "")
        } else {
            menu.addItem(withTitle: "置顶", action: #selector(menuPin(_:)), keyEquivalent: "")
            menu.addItem(withTitle: "删除", action: #selector(menuDelete(_:)), keyEquivalent: "")
        }
        for menuItem in menu.items { menuItem.target = self }
        let point = convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: nil, at: point, in: self)
    }

    @objc private func menuPin(_ sender: Any?) {
        guard !pendingActionIDs.isEmpty else { return }
        onPin?(pendingActionIDs)
        pendingActionIDs = []
    }

    @objc private func menuDelete(_ sender: Any?) {
        guard !pendingActionIDs.isEmpty else { return }
        onDelete?(pendingActionIDs)
        pendingActionIDs = []
    }

    private func updateInteractions() {
        // 覆盖层常显（含不可达条目，用于选中 / 右键）；拖拽发起由 isReachable 守卫
        isHidden = (item == nil)
        // V2-7 预览提示：条目 hover 时提示空格预览（不可达条目无内容可预览，不提示）
        toolTip = (item?.isReachable == true) ? "空格预览" : nil
    }

    private func snapshotImage() -> NSImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        return NSImage(size: bounds.size, flipped: false) { rect in
            rep.draw(in: rect)
            return true
        }
    }
}

extension FilePromiseDragView: NSDraggingSource {
    /// 拖拽操作掩码用 .copy：file promise 的交付路径是"Finder 请求 → 我们回调写入"，
    /// 由 `FilePromiseDragManager.writePromiseToURL` 里的 moveItem 完成真实移动，
    /// 不让 Finder 自行处理源文件（否则货架无法感知、也无法按承诺回调移动）。
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        hasDraggingSession = false
        Self.isDragging = false
        alphaValue = 1.0
        // 非 promise 目标（微信/iTerm2 等）交付语义：拖拽会话结束且未触发 promise
        // 兑现的条目 → 移除货架条目（对方读取的是文件 URL 内容，文件本体仍在磁盘）。
        // Finder 场景兑现成功的条目已由 onMoveCompleted 回调移除（remove(ids:) 幂等）。
        if !activeManagers.isEmpty {
            let remaining = activeManagers.filter { !$0.didCompleteMove }
            if !remaining.isEmpty {
                onMoveCompleted?(Set(remaining.map(\.itemID)))
            }
        }
        activeManagers = []
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        // 拖拽正式开始时压暗条目（与按下反馈连续）
        alphaValue = 0.5
    }
}

/// SwiftUI 桥接：以 overlay 挂到条目视图上，把拖拽发起从 `.onDrag` 换成 file promise。
struct FilePromiseDragRepresentable: NSViewRepresentable {
    let item: ShelfItem
    var selectedIDs: Set<UUID>
    var selectedItems: [ShelfItem]
    var onClick: (SelectionModifier, UUID) -> Void
    var onMoveCompleted: (Set<UUID>) -> Void
    var onPin: (Set<UUID>) -> Void
    var onDelete: (Set<UUID>) -> Void

    func makeNSView(context: Context) -> FilePromiseDragView {
        let view = FilePromiseDragView()
        apply(view)
        return view
    }

    func updateNSView(_ nsView: FilePromiseDragView, context: Context) {
        apply(nsView)
    }

    private func apply(_ view: FilePromiseDragView) {
        view.item = item
        view.selectedItemIDs = selectedIDs
        view.selectedItems = selectedItems
        view.onClick = onClick
        view.onMoveCompleted = onMoveCompleted
        view.onPin = onPin
        view.onDelete = onDelete
    }
}

/// 子类化 NSFilePromiseProvider：在 promise 类型之外追加真实文件 URL 类型。
///
/// 背景（用户反馈 V2-M2 验收）：仅用 NSFilePromiseProvider 时拖到微信/iTerm2
/// "根本没出现文件"——微信/终端需要 `public.file-url` / `NSFilenamesPboardType`，
/// 而 promise 类型只有 Finder 等支持 promise 协议的目标才消费。
///
/// 为什么用"子类"而不是"包装 writer"（CombinedFilePromiseWriter）：
/// 系统对 NSDraggingItem 的 promise 拖拽有特殊处理——包装 writer 时追加的
/// fileURL 类型可能不会真实进入 pasteboard 类型列表（iTerm2 判定
/// `availableTypeFromArray:@[NSPasteboardTypeFileURL]` 看不到 → 直接拒绝）。
/// 子类化后系统仍识别为 promise provider（Finder 兑现正常），同时 override
/// writableTypes 追加的类型会真实写入类型列表。
final class CombinedFilePromiseProvider: NSFilePromiseProvider {
    var fileURL: URL = URL(fileURLWithPath: "/")

    init(fileType: String, delegate: NSFilePromiseProviderDelegate?, fileURL: URL) {
        self.fileURL = fileURL
        super.init()   // NSFilePromiseProvider() 是 designated init；fileType/delegate 通过属性设置
        self.fileType = fileType
        self.delegate = delegate
    }

    required init?(coder: NSCoder) {
        // NSFilePromiseProvider 的 coder init 不在 Swift 可见的 designated 链中，
        // 但我们从不真正解码 provider（拖拽 item 不归档），用 () 初始化即可。
        super.init()
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        // 追加真实文件 URL 类型（微信/iTerm2 等非 promise 目标需要）：
        //   - public.file-url：标准值应为 file:/// 形式的 URL 字符串（不是纯路径）
        //   - NSFilenamesPboardType：老式路径数组类型（iTerm2 等终端应用依赖）
        if !types.contains(.fileURL) {
            types.append(.fileURL)
        }
        let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        if !types.contains(filenamesType) {
            types.append(filenamesType)
        }
        return types
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .fileURL {
            // public.file-url 的标准表示：file:/// 形式的 URL 字符串
            return fileURL.absoluteString
        }
        if type.rawValue == "NSFilenamesPboardType" {
            // 老式路径数组：["/path/to/file"]
            return [fileURL.path]
        }
        return super.pasteboardPropertyList(forType: type)
    }
}
