import AppKit
import SwiftUI

/// Spike S2：file promise 拖出发起视图。
///
/// SwiftUI 的 `.onDrag` 只能返回 `NSItemProvider`，而 file promise 需要
/// `NSFilePromiseProvider`（二者都符合 NSPasteboardWriting 但无继承关系），
/// Apple 已确认 `.onDrag` 无法直接承载 file promise。因此拖拽发起走 AppKit：
/// 本视图以 overlay 形式盖在条目内容上，`mouseDown` 记录起点，`mouseDragged`
/// 超过阈值（10pt）后用 `NSDraggingItem(pasteboardWriter: promise)` 发起拖拽会话。
///
/// 视图随 SwiftUI 条目生命周期存活，天然强持有 `FilePromiseDragManager`，
/// 解决 NSFilePromiseProvider.delegate 是 weak、而 Finder 兑现承诺（拖放结束后
/// 异步回调）需要 delegate 存活的问题。
final class FilePromiseDragView: NSView {
    var item: ShelfItem? {
        didSet { updateInteractions() }
    }
    var onMoveCompleted: ((ShelfItem) -> Void)? {
        didSet { updateInteractions() }
    }

    /// 当前拖拽会话的 manager；provider.delegate 是 weak，需随本视图生命周期强持有
    private var activeManager: FilePromiseDragManager?
    private var mouseDownLocation: CGPoint = .zero
    private var hasDraggingSession = false

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

    override func mouseDragged(with event: NSEvent) {
        guard !hasDraggingSession else { return }
        guard let item, item.isReachable else { return }

        let distance = hypot(
            event.locationInWindow.x - mouseDownLocation.x,
            event.locationInWindow.y - mouseDownLocation.y
        )
        // 位移阈值：区分"点击/滚动"与"拖拽"，与 Finder 条目手感一致
        guard distance > 10 else { return }

        let manager = FilePromiseDragManager(item: item) { [weak self] moved in
            self?.onMoveCompleted?(moved)
        }
        activeManager = manager

        // 子类化 NSFilePromiseProvider（Apple 官方做法，见 buckleyisms.com 拖拽指南）：
        //   override writableTypes 追加 public.file-url + NSFilenamesPboardType。
        // 相比"包装 writer"：系统仍识别它为 promise provider（Finder 兑现正常），
        // 且追加类型会真实写入 pasteboard 类型列表（微信/iTerm2 能看到并接受）。
        // 背景：仅 promise 时微信/iTerm2 收不到文件（它们需要 public.file-url）；
        //       包装 writer 时类型列表可能缺失 fileURL（系统对 promise 特殊处理）。
        let promise = CombinedFilePromiseProvider(
            fileType: FilePromiseDragManager.promiseFileType(for: item),
            delegate: manager,
            fileURL: item.fileURL
        )
        let draggingItem = NSDraggingItem(pasteboardWriter: promise)
        draggingItem.setDraggingFrame(
            NSRect(origin: .zero, size: frame.size),
            contents: snapshotImage()
        )
        beginDraggingSession(with: [draggingItem], event: event, source: self)
        hasDraggingSession = true
    }

    private func updateInteractions() {
        isHidden = item.map { !$0.isReachable } ?? true
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
        alphaValue = 1.0
        // 非 promise 目标（微信/iTerm2 等）交付语义：拖拽会话结束且没有触发
        // promise 兑现（activeManager 仍在 = move 未回调）→ 货架条目移除，
        // 源文件保留原位（对方读取的是文件 URL 内容，文件本体仍在磁盘）。
        // Finder 场景 move 成功会走 onMoveCompleted（activeManager 在成功时回调
        // 后仍持有，但此时条目已被移除——幂等保护由 ShelfStore.remove 承担）。
        if let item, let manager = activeManager, !manager.didCompleteMove {
            onMoveCompleted?(item)
        }
        activeManager = nil
    }

    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        // 拖拽正式开始时压暗条目（与按下反馈连续）
        alphaValue = 0.5
    }
}

/// SwiftUI 桥接：以 overlay 挂到条目视图上，把拖拽发起从 `.onDrag` 换成 file promise。
struct FilePromiseDragRepresentable: NSViewRepresentable {
    let item: ShelfItem
    var onMoveCompleted: (ShelfItem) -> Void

    func makeNSView(context: Context) -> FilePromiseDragView {
        let view = FilePromiseDragView()
        view.item = item
        view.onMoveCompleted = onMoveCompleted
        return view
    }

    func updateNSView(_ nsView: FilePromiseDragView, context: Context) {
        nsView.item = item
        nsView.onMoveCompleted = onMoveCompleted
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
