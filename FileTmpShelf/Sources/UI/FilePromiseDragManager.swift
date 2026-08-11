import AppKit
import UniformTypeIdentifiers

/// Spike S2：file promise 拖出移动 —— 把 Finder 的"承诺交付"回调实现为真实移动。
///
/// 背景：ShelfItemView 原用 `NSItemProvider(object: fileURL)` 拖出，Finder 收到的是
/// `public.file-url` 引用 -> 复制语义（源文件保留）。本类改用 `NSFilePromiseProvider`：
/// Finder 在目标位置请求写入时回调 `writePromiseToURL`，我们在回调里执行移动，
/// 实现"承诺交付 = 移动"；移动成功后通知货架移除该条目。
///
/// V2-5 跨卷真实移动：`FileManager.moveItem` 同卷是原子重命名（零拷贝）；跨卷时系统
/// 内部退化为"复制+删除源"，但没有"复制完整性"校验窗口——若复制中途失败，目标残留
/// 不完整副本且源可能已被删（数据风险）。本实现按卷差异分两条路径：
///   - 同卷：保持原 moveItem 原子路径（行为不可变，无复制成本）。
///   - 跨卷：显式 `copyItem` -> 校验目标完整（文件=存在+大小一致；目录=递归条目数
///     一致）-> 校验通过才删源；校验失败不删源（数据零丢失）并尽力清理不完整目标。
///
/// 数据零丢失（最高优先级）：所有失败路径（复制失败 / 校验失败 / 删源失败）都保留
/// 源文件；`moveItem`/`copyItem` 对失败是原子性的，不会出现"源已删但目标缺失"的中间态；
/// 只有移动成功才触发货架移除回调，失败时条目回滚保留。
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
    /// 跨卷移动的错误类型（供 UI / 测试区分失败阶段）
    enum FilePromiseMoveError: LocalizedError {
        /// 复制到目标卷失败（目标可能残留不完整副本，已尽力清理）
        case copyFailed(cause: Error)
        /// 复制后校验未通过（源已保留，目标已尽力清理）
        case verificationFailed(destination: URL)
        /// 校验通过但删除源失败（目标完整副本已回滚清理，源保留）
        case sourceRemoveFailed(cause: Error)

        var errorDescription: String? {
            switch self {
            case .copyFailed(let cause):
                return "复制到目标卷失败（源文件已保留）：\(cause.localizedDescription)"
            case .verificationFailed(let destination):
                return "跨卷复制校验失败（源文件已保留）：\(destination.path)"
            case .sourceRemoveFailed(let cause):
                return "校验通过但删除源文件失败（已回滚目标副本，源文件保留）：\(cause.localizedDescription)"
            }
        }
    }

    private let item: ShelfItem
    private let fileManager: FileManager
    /// 移动成功后的回调（在 MainActor 上执行），用于通知货架移除条目
    private let onMoveCompleted: (ShelfItem) -> Void
    /// 跨卷判定注入点：nil 时用真实卷标识比较（volumeIdentifier）；
    /// 测试用同一文件系统的不同顶层目录模拟"两个卷"（volumeIdentifier 相同，无法自判）。
    private let volumeResolver: ((URL, URL) -> Bool)?
    /// 复制完成后的校验注入点：nil 时用真实校验（文件=大小，目录=递归条目数）。
    /// 注入用于测试校验失败路径（无法在真实文件系统上制造"复制不完整但存在"）。
    private let copyVerifier: ((URL, URL) -> Bool)?

    init(
        item: ShelfItem,
        fileManager: FileManager = .default,
        onMoveCompleted: @escaping (ShelfItem) -> Void,
        volumeResolver: ((URL, URL) -> Bool)? = nil,
        copyVerifier: ((URL, URL) -> Bool)? = nil
    ) {
        self.item = item
        self.fileManager = fileManager
        self.onMoveCompleted = onMoveCompleted
        self.volumeResolver = volumeResolver
        self.copyVerifier = copyVerifier
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

    /// 可单测的移动核心：按源/目标卷关系分派。
    /// - 同卷：`FileManager.moveItem` 原子重命名（零拷贝，行为与 S2 完全一致）
    /// - 跨卷：复制 -> 校验 -> 删除源（V2-5），校验失败保留源
    func performMove(to destinationURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        if isCrossVolume(source: item.fileURL, destination: destinationURL) {
            moveCrossVolume(from: item.fileURL, to: destinationURL, completion: completion)
        } else {
            moveSameVolume(from: item.fileURL, to: destinationURL, completion: completion)
        }
    }

    /// 跨卷判定：比较源/目标所在卷的 `volumeIdentifier`（同卷一致、跨卷不同，比卷名可靠
    /// ——同名卷名不唯一）。
    /// 拿不到卷标识（路径异常等）时保守回退"同卷路径"（原子 moveItem 最安全）。
    private func isCrossVolume(source: URL, destination: URL) -> Bool {
        if let volumeResolver {
            return volumeResolver(source, destination)
        }
        guard let sourceVol = volumeIdentifier(for: source),
              let destVol = volumeIdentifier(for: destination) else {
            return false
        }
        return sourceVol != destVol
    }

    /// `volumeIdentifierKey` 的载荷类型因 SDK 而异（旧版 NSUUID、新版 8 字节 NSData），
    /// 统一提取为可比较的 `Data` 再比较，跨 SDK 稳定。
    private func volumeIdentifier(for url: URL) -> Data? {
        let raw = try? url.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        return raw as? Data
    }

    /// 同卷路径（S2 原行为，不可变）：moveItem 原子重命名。
    /// - 成功：源消失、目标出现
    /// - 失败：moveItem 抛错（目标目录缺失 / 无权限 / 同名冲突等），源文件保持原位
    private func moveSameVolume(from sourceURL: URL, to destinationURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            completion(.success(()))
        } catch {
            completion(.failure(error))
        }
    }

    /// 跨卷路径（V2-5）：复制 -> 校验 -> 删源 的三阶段，把"校验窗口"从 moveItem 内部
    /// 提到我们可控的代码里：
    ///   1. `copyItem` 显式复制（失败时源保持原位，尽力清理不完整目标）
    ///   2. 校验目标完整（见 `verifyCopy`）
    ///      - 通过 -> 删除源 -> 成功
    ///      - 失败 -> 不删源（数据零丢失）-> 尽力清理不完整目标 -> completionHandler(error)
    ///   3. 校验通过但删源失败：源保留（数据零丢失），回滚删除完整副本，避免"半移动"重复态
    /// 任何失败阶段都不触发 `onMoveCompleted`（货架条目回滚保留）。
    private func moveCrossVolume(from sourceURL: URL, to destinationURL: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            print("[FilePromiseMove] 跨卷复制失败（源保留）: \(error)")
            cleanupIncompleteDestination(destinationURL)
            completion(.failure(FilePromiseMoveError.copyFailed(cause: error)))
            return
        }

        logCopyMetrics(source: sourceURL, destination: destinationURL)

        guard verifyCopy(source: sourceURL, destination: destinationURL) else {
            print("[FilePromiseMove] 跨卷校验失败，保留源并清理不完整目标: \(destinationURL.path)")
            cleanupIncompleteDestination(destinationURL)
            completion(.failure(FilePromiseMoveError.verificationFailed(destination: destinationURL)))
            return
        }

        do {
            try fileManager.removeItem(at: sourceURL)
            print("[FilePromiseMove] 跨卷移动完成（校验通过后删除源）: \(destinationURL.path)")
            completion(.success(()))
        } catch {
            print("[FilePromiseMove] 校验通过但删除源失败，回滚删除目标副本: \(error)")
            cleanupIncompleteDestination(destinationURL)
            completion(.failure(FilePromiseMoveError.sourceRemoveFailed(cause: error)))
        }
    }

    /// 复制完整性校验（stat 级，不读内容）：
    /// - 普通文件：目标存在 + 文件大小 == 源大小。选 stat 而非内容比对——避免大文件
    ///   全量读取（时间/IO 成本），size 一致 + 存在已足以覆盖"复制中断残留"场景。
    ///   注意：大小用 `attributesOfItem`（stat），不用 `URLResourceValues.fileSize`——
    ///   后者按 URL 缓存，复制替换目标后可能读到旧大小（macOS 已知行为），会产生误判。
    /// - 目录：目标存在 + 递归条目数 == 源条目数。选条目数而非全树 hash/逐文件 size 比对
    ///   ——避免复制巨大目录树时的全量遍历开销；条目数不一致即判定复制不完整。
    /// - 符号链接/其他：保守按目标存在判定（不 stat 解析目标，避免误判）。
    func verifyCopy(source: URL, destination: URL) -> Bool {
        if let copyVerifier {
            return copyVerifier(source, destination)
        }
        guard let sourceAttrs = try? fileManager.attributesOfItem(atPath: source.path) else { return false }
        guard let destAttrs = try? fileManager.attributesOfItem(atPath: destination.path) else { return false }

        let sourceType = sourceAttrs[.type] as? FileAttributeType
        let destType = destAttrs[.type] as? FileAttributeType

        if sourceType == .typeRegular {
            let sourceSize = (sourceAttrs[.size] as? NSNumber)?.int64Value ?? -1
            let destSize = (destAttrs[.size] as? NSNumber)?.int64Value ?? -1
            return destType == .typeRegular && sourceSize == destSize
        }
        if sourceType == .typeDirectory {
            return destType == .typeDirectory
                && recursiveItemCount(at: source) == recursiveItemCount(at: destination)
        }
        return fileManager.fileExists(atPath: destination.path)
    }

    /// 目录递归条目数（enumerator 含子目录内所有条目，不含目录本身；空目录=0）。
    /// 失败（不可读）返回 0——校验端会因两数不等而判失败，符合"保守保留源"原则。
    private func recursiveItemCount(at url: URL) -> Int {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil, options: [], errorHandler: nil) else {
            return 0
        }
        var count = 0
        for _ in enumerator {
            count += 1
        }
        return count
    }

    /// 尽力清理不完整/回滚的目标副本。清理失败只记日志，不向调用方再报错
    /// （不能让"清理失败"覆盖掉原本的错误，也不允许引入新的失败路径）。
    private func cleanupIncompleteDestination(_ url: URL) {
        do {
            try fileManager.removeItem(at: url)
            print("[FilePromiseMove] 已清理目标残留: \(url.path)")
        } catch {
            print("[FilePromiseMove] 清理目标残留失败（忽略）: \(error)")
        }
    }

    /// 大文件进度提示的取舍说明：
    /// 真实进度（拖拽期间 NSProgress / 状态文字）需要自实现"分块读-写流"并在每块后更新
    /// `Progress.completedUnitCount`，`FileManager.copyItem` 不暴露进度回调；自实现分块
    /// 复制超出本里程碑范围。当前以日志记录复制字节量（完成后一行），UI 层后续如需进度
    /// 可基于本方法改造为分块复制 + Progress 上报。
    private func logCopyMetrics(source: URL, destination: URL) {
        let size = (try? fileManager.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber
        print("[FilePromiseMove] 跨卷复制完成: \(size?.int64Value ?? 0) bytes \(source.path) → \(destination.path)")
    }

    private func notifyMoveCompleted() {
        Task { @MainActor in
            onMoveCompleted(item)
        }
    }
}
