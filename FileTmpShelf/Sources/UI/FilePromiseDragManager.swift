import AppKit
import UniformTypeIdentifiers

/// Spike S2：file promise 拖出移动 —— 把 Finder 的"承诺交付"回调实现为真实移动。
///
/// 背景：ShelfItemView 原用 `NSItemProvider(object: fileURL)` 拖出，Finder 收到的是
/// `public.file-url` 引用 -> 复制语义（源文件保留）。本类改用 `NSFilePromiseProvider`：
/// Finder 在目标位置请求写入时回调 `writePromiseToURL`，我们在回调里执行
/// `FileManager.moveItem`，实现"承诺交付 = 移动"；移动成功后通知货架移除该条目。
///
/// 数据零丢失：`FileManager.moveItem` 失败时源文件保持原位（moveItem 对失败是原子性的，
/// 不会出现"源已删除但目标缺失"的中间态）；并且只有移动成功才触发货架移除回调，
/// 失败时条目回滚保留。
///
/// 并发模型：`writePromiseToURL` 是 NS_SWIFT_NONISOLATED（在 `operationQueue(for:)`
/// 返回的后台队列上执行），`fileNameForType` / `operationQueue` 是 @MainActor 隔离。
/// 本类故意不做整类 @MainActor，避免非隔离回调访问存储属性时报并发错误；
/// 移动核心 `moveAndNotify` / `performMove` 保持非隔离，便于单测直接驱动。
///
/// 生命周期：SwiftUI 的 `.onDrag` 只能返回 NSItemProvider（Apple 已确认无法直接塞入
/// NSFilePromiseProvider），故拖拽发起走 AppKit 的 `FilePromiseDragView`
/// （`beginDraggingSession` + `NSDraggingItem(pasteboardWriter:)`），由该 view 强持有
/// 本 manager，保证 Finder 兑现承诺（拖放结束后异步回调）时 manager 未被释放。
final class FilePromiseDragManager: NSObject, NSFilePromiseProviderDelegate {
    private let item: ShelfItem
    private let fileManager: FileManager
    /// 移动成功后的回调（在 MainActor 上执行），用于通知货架移除条目
    private let onMoveCompleted: (ShelfItem) -> Void

    init(item: ShelfItem, fileManager: FileManager = .default, onMoveCompleted: @escaping (ShelfItem) -> Void) {
        self.item = item
        self.fileManager = fileManager
        self.onMoveCompleted = onMoveCompleted
        super.init()
    }

    /// 承诺文件的 UTI：普通文件取真实类型（Apple 官方示例做法），文件夹用 public.folder，
    /// 未知扩展名回退到 public.data。fileType 必须 conform 到 kUTTypeData/kUTTypeDirectory，
    /// 否则 NSFilePromiseProvider 抛异常。
    /// 注意：UTType(filenameExtension:) 对未知扩展名会生成动态 UTI（dyn.*，如
    /// dyn.ah62d4rv4ge81u8p4tm6u）而非 nil——动态类型不可用于 promise fileType，
    /// 必须过滤（isDynamic）并回退到 public.data。
    static func promiseFileType(for item: ShelfItem) -> String {
        let url = item.fileURL
        if url.hasDirectoryPath {
            return UTType.directory.identifier
        }
        if let type = UTType(filenameExtension: url.pathExtension), !type.isDynamic {
            return type.identifier
        }
        return UTType.data.identifier
    }

    /// 承诺文件的最终文件名（Finder 据此拼出目标 URL，再回调 writePromiseToURL）
    @MainActor
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        item.displayName
    }

    /// 承诺交付执行队列：独立 OperationQueue，避免大文件（跨卷 moveItem 是真实拷贝）阻塞主线程
    @MainActor
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        let queue = OperationQueue()
        queue.name = "FileTmpShelf.FilePromiseMove"
        queue.qualityOfService = .userInitiated
        return queue
    }

    /// Finder 兑现承诺：把源文件真实移动到 `url`（该 URL 已含文件名，无需自行拼接）。
    /// 成功 -> completionHandler(nil) + 主线程通知货架移除；
    /// 失败 -> completionHandler(error)，源文件保持原位（数据零丢失）。
    nonisolated func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping @Sendable ((any Error)?) -> Void
    ) {
        moveAndNotify(to: url, completionHandler: completionHandler)
    }

    /// 执行移动并处理结果。`writePromiseToURL` 的核心流程，抽出以便单测直接驱动
    /// （NSFilePromiseProvider 的 Finder 兑现回调依赖真实拖拽会话，无法在单测触发）。
    /// - 成功：completionHandler(nil) + 通知货架移除
    /// - 失败：completionHandler(error)，源文件保持原位（数据零丢失），货架条目保留
    func moveAndNotify(to url: URL, completionHandler: @escaping (Error?) -> Void) {
        performMove(to: url) { [weak self] result in
            switch result {
            case .success:
                completionHandler(nil)
                self?.notifyMoveCompleted()
            case .failure(let error):
                completionHandler(error)
            }
        }
    }

    /// 可单测的移动核心：FileManager.moveItem 封装。
    /// - 成功：源文件消失、目标文件出现
    /// - 失败：moveItem 抛错（目标目录缺失 / 无权限 / 同名冲突等），源文件保持原位
    func performMove(to destinationURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            try fileManager.moveItem(at: item.fileURL, to: destinationURL)
            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
    }

    private func notifyMoveCompleted() {
        Task { @MainActor in
            onMoveCompleted(item)
        }
    }
}
