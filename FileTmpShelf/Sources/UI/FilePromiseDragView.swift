import AppKit
import SwiftUI

/// file promise 拖出发起视图（S2 核心 + V2-6 多选/多文件）。
///
/// SwiftUI 的 `.onDrag` 只能返回 `NSItemProvider`，而 file promise 需要
/// `NSFilePromiseProvider`（二者都符合 NSPasteboardWriting 但无继承关系），
/// Apple 已确认 `.onDrag` 无法直接承载 file promise。因此拖拽发起走 AppKit：
/// 本视图以 overlay 形式盖在条目内容上，`mouseDown` 记录起点，`mouseDragged`
/// 超过阈值（10pt）后用 `NSDraggingItem(pasteboardWriter: promise)` 发起拖拽会话。
///
/// 多选（V2-6）：mouseUp 区分点击选择（⌘ 切换 / Shift 区间 / 无修饰键单选），
/// 被拖条目在选中集中且多选时 → 批量拖出整个选中集。
///
/// 生命周期关键（Bug4 教训）：NSFilePromiseProvider.delegate 是 weak，Finder
/// 兑现承诺（drop 后异步回调 writePromiseToURL）需要 manager 存活。**不能在
/// draggingSession endedAt 里立即清空 managers**——兑现回调可能在 endedAt 之后
/// 才到达，提前释放会致 Finder 兑现失败（生成 .textClipping）。managers 由
/// 本视图强持有，直到兑现完成或视图销毁。
final class FilePromiseDragView: NSView {
    var item: ShelfItem? {
        didSet { updateInteractions() }
    }
    /// 单文件移动完成回调（Finder 兑现成功 → 移除货架条目）
    var onMoveCompleted: ((ShelfItem) -> Void)? {
        didSet { updateInteractions() }
    }
    /// 点击选择回调：modifier 分类 + 条目 id（UI 层翻译为选择状态）
    var onClick: ((SelectionModifier, UUID) -> Void)? {
        didSet { updateInteractions() }
    }
    /// 当前选中集合（决定批量拖出集合）
    var selectedItemIDs: Set<UUID> = [] {
        didSet { updateInteractions() }
    }
    /// 当前选中条目（按货架顺序，批量拖出用）
    var selectedItems: [ShelfItem] = [] {
        didSet { updateInteractions() }
    }

    /// 当前拖拽会话的 manager 列表；provider.delegate 是 weak，需随本视图生命周期强持有。
    /// 不随 endedAt 立即清空（Finder 兑现异步，见类注释）。
    private var activeManagers: [FilePromiseDragManager] = []
    private var mouseDownLocation: CGPoint = .zero
    private var hasDraggingSession = false
    /// 静态拖拽标记（防止拖拽中误触发其他交互，如 Quick Look）
    static var isDragging = false

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

    /// 鼠标落在条目区域拖动时，事件应只用于发起文件拖拽，不允许窗口解释为"移动窗口"。
    override var mouseDownCanMoveWindow: Bool {
        false
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
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

        // 批量拖出：被拖条目在选中集中且多选 → 拖出整个选中集；否则仅拖出自身
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
            // 按整批 id 移除货架条目。
            // ⚠️ 修复（多文件首文件移动后其余显示不可达）：不能 `[weak self]` 捕获视图——
            // 首文件兑现移除条目后，发起拖拽的视图被销毁、self 变 nil，其余文件的
            // 移除回调全部失效（源已移动但条目残留 → 显示「不可达」）。直接捕获
            // onMoveCompleted 闭包（其内部持有 model，长生命周期），视图销毁后仍有效。
            let moveCompleted = onMoveCompleted
            let manager = FilePromiseDragManager(item: target) { _ in
                moveCompleted?(target)
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
        // 强持有 managers：Finder 兑现是 drop 后异步回调，manager 提前释放会兑现失败
        activeManagers = managers
        Self.isDragging = true
        beginDraggingSession(with: draggingItems, event: event, source: self)
        hasDraggingSession = true
    }

    private func updateInteractions() {
        isHidden = (item == nil)
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
    /// 由 `FilePromiseDragManager.writePromiseToURL` 里的 moveItem 完成真实移动。
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
        // Bug4 教训：不在此清空 activeManagers！Finder 兑现是 drop 后异步回调，
        // 提前释放 manager 会让 NSFilePromiseProvider.delegate 悬垂 → 兑现失败
        // → Finder 生成 .textClipping。managers 保持由本视图持有直到兑现完成。
        // operation 保留供外部判断（当前单/多文件兑现路径均通过 onMoveCompleted 回调）。
        _ = operation
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        alphaValue = 0.5
    }
}

/// SwiftUI 桥接：以 overlay 挂到条目视图上，把拖拽发起从 `.onDrag` 换成 file promise。
struct FilePromiseDragRepresentable: NSViewRepresentable {
    let item: ShelfItem
    var onMoveCompleted: (ShelfItem) -> Void
    var onClick: (SelectionModifier, UUID) -> Void
    var selectedItemIDs: Set<UUID>
    var selectedItems: [ShelfItem]

    func makeNSView(context: Context) -> FilePromiseDragView {
        let view = FilePromiseDragView()
        view.item = item
        view.onMoveCompleted = onMoveCompleted
        view.onClick = onClick
        view.selectedItemIDs = selectedItemIDs
        view.selectedItems = selectedItems
        return view
    }

    func updateNSView(_ nsView: FilePromiseDragView, context: Context) {
        nsView.item = item
        nsView.onMoveCompleted = onMoveCompleted
        nsView.onClick = onClick
        nsView.selectedItemIDs = selectedItemIDs
        nsView.selectedItems = selectedItems
    }
}

/// 子类化 NSFilePromiseProvider：在 promise 类型之外追加真实文件 URL 类型。
///
/// 背景（用户反馈 V2-M2 验收）：仅用 NSFilePromiseProvider 时拖到微信/iTerm2
/// "根本没出现文件"——微信/终端需要 `public.file-url`，
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
        super.init()
        self.fileType = fileType
        self.delegate = delegate
    }

    required init?(coder: NSCoder) {
        super.init()
    }

    override func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        var types = super.writableTypes(for: pasteboard)
        // 追加真实文件 URL 类型（微信/iTerm2 等非 promise 目标需要）：
        //   public.file-url：标准值应为 file:/// 形式的 URL 字符串（不是纯路径）
        // 注：不再追加 NSFilenamesPboardType——它是废弃的 pboard 类型常量、
        // 不是 UTI（UTType 解析为 nil），AppKit 在 writableTypes 里返回它会被
        // 拒绝并刷「not a valid UTI」警告，且从未真正进入类型列表（死代码）。
        // 微信/iTerm2 的兼容实际由 public.file-url 承担（C-9 清理）。
        if !types.contains(.fileURL) {
            types.append(.fileURL)
        }
        return types
    }

    override func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .fileURL {
            // public.file-url 的标准表示：file:/// 形式的 URL 字符串
            return fileURL.absoluteString
        }
        return super.pasteboardPropertyList(forType: type)
    }

    /// 关键（buckleyisms.com 指南）：子类化追加类型时必须 override writingOptions。
    /// 追加的非文件类型（fileURL）返回空选项（标准写入），
    /// promise 类型返回 super（保留 promise 兑现语义）。缺失此方法会导致
    /// Finder 对拖拽的兑现/类型处理异常（Bug4 的 UUID 文件 + .textClipping）。
    override func writingOptions(
        forType type: NSPasteboard.PasteboardType,
        pasteboard: NSPasteboard
    ) -> NSPasteboard.WritingOptions {
        if type == .fileURL {
            return []
        }
        return super.writingOptions(forType: type, pasteboard: pasteboard)
    }
}
