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

/// 货架元数据：多货架模式下 `shelves.json`（registry）中的一条记录。
struct ShelfMeta: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
}

/// 货架存储：内存索引 + 持久化（JSON 落盘）。
/// 存储模型为"路径引用"，应用数据目录仅存元数据索引（<1KB/条目）。
///
/// V2-4 多货架：默认模式（base 目录）下每个货架独立存储 `shelf-<id>.json`，
/// `shelves.json` 记录货架列表（id + 名称）。旧版单文件模式（构造时传 `.json`
/// 文件路径，兼容既有测试/调用方）保持原行为：单货架直接读写该文件。
actor ShelfStore {
    /// 迁移/默认货架名称
    static let defaultShelfName = "默认货架"

    private let baseURL: URL
    /// 非 nil = 旧版单文件模式（构造时传 .json 文件路径，向后兼容）
    private let legacyFileURL: URL?

    /// 当前货架条目（内存）——单文件模式即为唯一货架的条目
    private var items: [ShelfItem] = []
    /// 多货架模式：当前货架 id
    private var currentID: UUID?
    /// 多货架模式：货架列表（registry）
    private var shelfMetas: [ShelfMeta] = []

    init(storageURL: URL? = nil) {
        if let storageURL, storageURL.pathExtension.lowercased() == "json" {
            // 旧版单文件模式：storageURL 是直接的文件路径
            baseURL = storageURL.deletingLastPathComponent()
            legacyFileURL = storageURL
        } else {
            // 多货架模式：storageURL 是存储根目录（或默认应用支持目录）
            baseURL = storageURL
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("FileTmpShelf", isDirectory: true)
            legacyFileURL = nil
        }
    }

    private var registryURL: URL { baseURL.appendingPathComponent("shelves.json") }
    private func shelfFileURL(for id: UUID) -> URL {
        baseURL.appendingPathComponent("shelf-\(id.uuidString).json")
    }

    // MARK: - 当前货架

    /// 当前货架条目数
    var count: Int { items.count }

    /// 全部货架的条目总数（设置页「清除所有货架」确认文案用）
    var totalItemCount: Int {
        if let legacyFileURL {
            return items.count
        }
        return shelfMetas.reduce(0) { $0 + readItems(from: shelfFileURL(for: $1.id)).count }
    }

    func all() -> [ShelfItem] { items }

    /// 货架列表（含 id/名称；单文件模式返回空）
    func shelves() -> [ShelfMeta] { shelfMetas }

    /// 当前货架元数据（单文件模式返回 nil）
    func currentShelf() -> ShelfMeta? {
        guard let currentID else { return nil }
        return shelfMetas.first { $0.id == currentID }
    }

    /// 当前货架名称（无当前货架时回退默认名）
    var currentShelfName: String {
        shelfMetas.first { $0.id == currentID }?.name ?? Self.defaultShelfName
    }

    // MARK: - 多货架管理（V2-4）

    /// 切换当前货架：加载该货架条目
    func selectShelf(id: UUID) {
        guard shelfMetas.contains(where: { $0.id == id }) else { return }
        currentID = id
        items = readItems(from: shelfFileURL(for: id))
        logUnreachable()
    }

    /// 新建货架（空条目），并切换为当前货架。返回新货架 id，失败返回 nil。
    @discardableResult
    func createShelf(name: String) -> UUID? {
        let meta = ShelfMeta(id: UUID(), name: sanitizedName(name))
        do {
            try writeShelfFile(meta.id, items: [])
            var registry = shelfMetas
            registry.append(meta)
            try writeRegistry(registry)
            shelfMetas = registry
            currentID = meta.id
            items = []
            return meta.id
        } catch {
            print("[ShelfStore] 新建货架失败: \(error)")
            return nil
        }
    }

    /// 重命名货架（空名回退默认名）
    func renameShelf(id: UUID, name: String) {
        guard let idx = shelfMetas.firstIndex(where: { $0.id == id }) else { return }
        let clean = sanitizedName(name)
        guard clean != shelfMetas[idx].name else { return }
        shelfMetas[idx].name = clean
        try? writeRegistry(shelfMetas)
    }

    /// 删除货架（最后一个不允许删除，返回 false）。删除当前货架时回落到列表第一个。
    @discardableResult
    func deleteShelf(id: UUID) -> Bool {
        guard shelfMetas.count > 1, shelfMetas.contains(where: { $0.id == id }) else { return false }
        shelfMetas.removeAll { $0.id == id }
        try? writeRegistry(shelfMetas)
        try? FileManager.default.removeItem(at: shelfFileURL(for: id))
        if currentID == id {
            currentID = shelfMetas.first?.id
            items = currentID.map { readItems(from: shelfFileURL(for: $0)) } ?? []
            logUnreachable()
        }
        return true
    }

    /// 清空全部货架的条目（保留货架本身）。单文件模式即 removeAll。
    func clearAllShelves() {
        if let legacyFileURL {
            items = []
            persist()
            return
        }
        for meta in shelfMetas {
            try? writeShelfFile(meta.id, items: [])
        }
        if currentID != nil {
            items = []
        }
    }

    // MARK: - 条目操作（当前货架）

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

    // MARK: - 加载 / 迁移

    /// 启动时恢复 + 失效检测。多货架模式首次调用时执行 shelf.json → 默认货架迁移。
    func load() {
        if let legacyFileURL {
            items = readItems(from: legacyFileURL)
            logUnreachable()
            return
        }
        ensureRegistryAndMigrate()
        guard let currentID else {
            items = []
            return
        }
        items = readItems(from: shelfFileURL(for: currentID))
        logUnreachable()
    }

    /// 多货架模式：读 registry；不存在时迁移旧 shelf.json 或初始化默认货架。
    /// 迁移必须保守：旧 shelf.json 保留到「新文件 + registry」全部写入成功才删除；
    /// 任何一步失败保留旧文件，下次启动重试。
    private func ensureRegistryAndMigrate() {
        if let data = try? Data(contentsOf: registryURL),
           let metas = try? JSONDecoder().decode([ShelfMeta].self, from: data) {
            shelfMetas = metas
            if currentID == nil || !shelfMetas.contains(where: { $0.id == currentID }) {
                currentID = shelfMetas.first?.id
            }
            return
        }

        let legacyURL = baseURL.appendingPathComponent("shelf.json")
        let defaultMeta = ShelfMeta(id: UUID(), name: Self.defaultShelfName)
        if FileManager.default.fileExists(atPath: legacyURL.path),
           let data = try? Data(contentsOf: legacyURL),
           let legacyItems = try? JSONDecoder().decode([ShelfItem].self, from: data) {
            // 迁移：shelf.json → 默认货架
            do {
                try writeShelfFile(defaultMeta.id, items: legacyItems)
                try writeRegistry([defaultMeta])
                try FileManager.default.removeItem(at: legacyURL)
                shelfMetas = [defaultMeta]
                currentID = defaultMeta.id
                items = legacyItems
            } catch {
                // 任一步失败：保留 shelf.json，下次启动重试
                print("[ShelfStore] 迁移失败（保留旧文件下次重试）: \(error)")
                shelfMetas = []
                currentID = nil
                items = []
            }
            return
        }

        // 全新安装：创建默认货架
        do {
            try writeShelfFile(defaultMeta.id, items: [])
            try writeRegistry([defaultMeta])
            shelfMetas = [defaultMeta]
            currentID = defaultMeta.id
            items = []
        } catch {
            print("[ShelfStore] 初始化默认货架失败: \(error)")
            shelfMetas = []
            currentID = nil
            items = []
        }
    }

    // MARK: - 持久化

    private func persist() {
        if let legacyFileURL {
            persistItems(items, to: legacyFileURL)
            return
        }
        guard let currentID else { return }
        try? writeShelfFile(currentID, items: items)
    }

    private func writeShelfFile(_ id: UUID, items: [ShelfItem]) throws {
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(items)
        try data.write(to: shelfFileURL(for: id), options: .atomic)
    }

    private func persistItems(_ items: [ShelfItem], to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(items)
            try data.write(to: url, options: .atomic)
        } catch {
            print("[ShelfStore] 持久化失败: \(error)")
        }
    }

    private func writeRegistry(_ metas: [ShelfMeta]) throws {
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(metas)
        try data.write(to: registryURL, options: .atomic)
    }

    private func readItems(from url: URL) -> [ShelfItem] {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ShelfItem].self, from: data) else {
            return []
        }
        return decoded
    }

    private func logUnreachable() {
        for item in items where !item.isReachable {
            // 启动时标记失效条目（UI 层展示"文件不可达"）
            print("[ShelfStore] 失效条目: \(item.displayName) @ \(item.path)")
        }
    }

    private func sanitizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultShelfName : trimmed
    }
}

extension Notification.Name {
    /// 设置页「清除所有货架」完成后广播；面板视图据此从磁盘重载，
    /// 保证设置页清空后打开中的面板与磁盘数据一致。
    static let shelfDidClearAll = Notification.Name("FileTmpShelf.shelfDidClearAll")
}
