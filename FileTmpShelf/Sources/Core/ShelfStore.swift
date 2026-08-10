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
            .fileSizeKey,
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]
        guard let values = try? url.resourceValues(forKeys: resourceKeys) else {
            return nil
        }
        let isCloud = values.isUbiquitousItem ?? false
        // .current = 本地已有完整副本；.downloaded/.notDownloaded = 云端占位（未下载）
        let status = values.ubiquitousItemDownloadingStatus ?? .current
        let isPlaceholder = isCloud && status != .current
        let size = values.fileSize ?? 0
        return ShelfItem(
            path: url.path,
            displayName: url.lastPathComponent,
            fileSize: Int64(size),
            sourceParentPath: url.deletingLastPathComponent().path,
            isCloudPlaceholder: isPlaceholder
        )
    }

    var fileURL: URL { URL(fileURLWithPath: path) }

    /// 文件当前是否可达
    var isReachable: Bool {
        FileManager.default.fileExists(atPath: path)
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

    /// 批量挂载，返回挂载耗时（Spike S1 性能验证）
    func addBatch(_ urls: [URL]) -> (count: Int, elapsed: TimeInterval) {
        let start = Date()
        for url in urls {
            if let item = ShelfItem.make(from: url) {
                items.append(item)
            }
        }
        persist()
        return (items.count, Date().timeIntervalSince(start))
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
