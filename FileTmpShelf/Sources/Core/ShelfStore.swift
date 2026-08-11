import Foundation

/// 货架条目：一个被"挂"到货架上的文件/文件夹路径引用。
/// Spike S1 目标：验证非沙盒下直接存 URL 即可跨重启可达（无需 security-scoped bookmark），
/// 并处理 iCloud 占位文件等失效场景。
struct ShelfItem: Identifiable, Codable, Equatable {
    let id: UUID
    var path: String          // 源文件绝对路径
    var displayName: String   // 文件/文件夹名
    var fileSize: Int64       // 字节数（文件夹可为 0 或递归统计）
    var sourceParentPath: String // 来源父目录（UI 展示"来自哪里"）
    var addedAt: Date
    var isCloudPlaceholder: Bool // iCloud 占位文件（未下载）

    init(
        id: UUID = UUID(),
        path: String,
        displayName: String,
        fileSize: Int64,
        sourceParentPath: String,
        addedAt: Date = Date(),
        isCloudPlaceholder: Bool = false
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName
        self.fileSize = fileSize
        self.sourceParentPath = sourceParentPath
        self.addedAt = addedAt
        self.isCloudPlaceholder = isCloudPlaceholder
    }

    /// 从文件 URL 构建条目（不复制文件本体）
    static func make(from url: URL) -> ShelfItem? {
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]
        guard let values = try? url.resourceValues(forKeys: resourceKeys) else {
            return nil
        }
        let isCloud = values.isUbiquitousItem ?? false
        // 只有 .notDownloaded 才是真正的云端占位（本地仅有 .icloud 存根）；
        // .downloaded 已有本地副本（可能略旧于云端），.current 为最新本地副本。
        let status = values.ubiquitousItemDownloadingStatus ?? .current
        let isPlaceholder = isCloud && status == .notDownloaded

        // fileSize 语义：普通文件取本体大小；目录的 fileSize 只是目录条目元数据（非递归），记 0；
        // 符号链接按目标解析——目标为普通文件取目标大小，悬空链接/链接到目录记 0。
        let fileSize: Int64
        if values.isRegularFile == true {
            fileSize = Int64(values.fileSize ?? 0)
        } else if values.isSymbolicLink == true {
            let resolved = url.resolvingSymlinksInPath()
            let targetValues = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            fileSize = (targetValues?.isRegularFile == true) ? Int64(targetValues?.fileSize ?? 0) : 0
        } else {
            fileSize = 0
        }

        return ShelfItem(
            path: url.path,
            displayName: url.lastPathComponent,
            fileSize: fileSize,
            sourceParentPath: url.deletingLastPathComponent().path,
            isCloudPlaceholder: isPlaceholder
        )
    }

    var fileURL: URL { URL(fileURLWithPath: path) }

    /// 文件当前是否可达（iCloud 占位仅剩 .icloud 存根，视为不可达）
    var isReachable: Bool {
        guard !isCloudPlaceholder else { return false }
        return FileManager.default.fileExists(atPath: path)
    }
}

/// 货架存储：内存索引 + 持久化（JSON 落盘）。
/// 存储模型为"路径引用"，应用数据目录仅存元数据索引（<1KB/条目）。
actor ShelfStore {
    private var items: [ShelfItem] = []
    private let storageURL: URL

    init(storageURL: URL? = nil) {
        let base = storageURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("FileTmpShelf", isDirectory: true)
        self.storageURL = base.appendingPathComponent("shelf.json")
    }

    var count: Int { items.count }

    func all() -> [ShelfItem] {
        items
    }

    /// 挂载（零拷贝）：只记录路径引用
    func add(_ item: ShelfItem) {
        items.append(item)
        persist()
    }

    /// 批量挂载，返回本次成功挂载数、被跳过的 URL 与总耗时（Spike S1 性能验证）。
    /// 注：返回的 count 为本次实际挂载数（非货架总数），便于 UI 提示"哪些没挂上"。
    func addBatch(_ urls: [URL]) -> (count: Int, skipped: [URL], elapsed: TimeInterval) {
        let start = Date()
        var skipped: [URL] = []
        var mounted = 0
        for url in urls {
            if let item = ShelfItem.make(from: url) {
                items.append(item)
                mounted += 1
            } else {
                skipped.append(url)
            }
        }
        persist()
        return (mounted, skipped, Date().timeIntervalSince(start))
    }

    /// 移除条目（拖出成功 / 用户清空 / 失效清理）
    func remove(id: UUID) {
        items.removeAll { $0.id == id }
        persist()
    }

    func removeAll() {
        items.removeAll()
        persist()
    }

    /// 清理失效条目（源文件已删除/移动/不可达），返回被清理的数量。
    /// 体验增强 3.2：一键清理失效引用，无数据风险（只移除引用不碰文件）。
    @discardableResult
    func removeUnreachable() -> Int {
        let before = items.count
        items.removeAll { !$0.isReachable }
        persist()
        return before - items.count
    }

    /// 失效条目数量（供 UI 决定是否显示"清理失效"按钮）
    func unreachableCount() -> Int {
        items.filter { !$0.isReachable }.count
    }

    /// 启动时恢复 + 失效检测（Spike S1：失效矩阵验证）
    func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) else {
            items = []
            return
        }
        items = decoded
        for item in items where !item.isReachable {
            // 启动时标记失效条目（UI 层展示"文件不可达"）
            print("[ShelfStore] 失效条目: \(item.displayName) @ \(item.path)")
        }
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(items)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("[ShelfStore] 持久化失败: \(error)")
        }
    }
}

extension Notification.Name {
    /// 设置页「清除所有货架」完成后广播；面板视图据此从磁盘重载，
    /// 保证设置页清空后打开中的面板与磁盘数据一致。
    static let shelfDidClearAll = Notification.Name("FileTmpShelf.shelfDidClearAll")
}
