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

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = event.locationInWindow
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

        let promise = NSFilePromiseProvider(
            fileType: FilePromiseDragManager.promiseFileType(for: item),
            delegate: manager
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
