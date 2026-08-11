import XCTest
@testable import FileTmpShelf

final class ShelfStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileTmpShelfTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeTestFile(named name: String, size: Int) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        let data = Data(repeating: 0x41, count: size)
        try data.write(to: url)
        return url
    }

    func testAddBatchCreatesItemsWithoutCopying() async throws {
        let store = ShelfStore(storageURL: tempDir.appendingPathComponent("shelf1.json"))
        let file1 = try makeTestFile(named: "a.txt", size: 1024)
        let file2 = try makeTestFile(named: "b.txt", size: 2048)

        let outcome = await store.addBatch([file1, file2])

        XCTAssertEqual(outcome.count, 2)
        // 零拷贝验证：原文件仍存在且内容未被改动
        let items = await store.all()
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file1.path))
        XCTAssertEqual(try Data(contentsOf: file1).count, 1024)
    }

    func testPersistAndReloadRoundTrip() async throws {
        let storeURL = tempDir.appendingPathComponent("shelf2.json")
        let store = ShelfStore(storageURL: storeURL)
        let file = try makeTestFile(named: "c.txt", size: 512)
        _ = await store.addBatch([file])

        // 模拟重启：新实例 load
        let reloaded = ShelfStore(storageURL: storeURL)
        await reloaded.load()
        let items = await reloaded.all()

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.displayName, "c.txt")
        XCTAssertEqual(items.first?.sourceParentPath, tempDir.path)
    }

    func testRemoveItem() async throws {
        let store = ShelfStore(storageURL: tempDir.appendingPathComponent("shelf3.json"))
        let file = try makeTestFile(named: "d.txt", size: 10)
        _ = await store.addBatch([file])
        let items = await store.all()
        XCTAssertEqual(items.count, 1)

        await store.remove(id: items[0].id)
        let after = await store.all()
        XCTAssertEqual(after.count, 0)
    }

    func testReachabilityDetectsDeletedSource() async throws {
        let store = ShelfStore(storageURL: tempDir.appendingPathComponent("shelf4.json"))
        let file = try makeTestFile(named: "e.txt", size: 10)
        _ = await store.addBatch([file])
        let items = await store.all()

        try FileManager.default.removeItem(at: file)
        XCTAssertFalse(items[0].isReachable)
    }

    func testCloudPlaceholderDetection() async throws {
        let store = ShelfStore(storageURL: tempDir.appendingPathComponent("shelf5.json"))
        let file = try makeTestFile(named: "f.txt", size: 10)
        _ = await store.addBatch([file])
        let items = await store.all()
        // 本地普通文件不应被标记为 iCloud 占位
        XCTAssertFalse(items[0].isCloudPlaceholder)
    }

    // MARK: - Spike S1 扩展边界测试

    private func makeTestFile(named name: String, content: String = "hello") throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try content.data(using: .utf8)!.write(to: url)
        return url
    }

    private func makeTestDirectory(named name: String, withTree tree: [String]) throws -> URL {
        let dir = tempDir.appendingPathComponent(name, isDirectory: true)
        for relative in tree {
            let path = dir.appendingPathComponent(relative)
            if relative.hasSuffix("/") {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            } else {
                try Data(repeating: 0x42, count: 64).write(to: path)
            }
        }
        return dir
    }

    /// 文件夹挂载：目录树可挂载，displayName 正确，fileSize 为 0（非递归，避免误导）
    func testFolderMountDirectoryTree() async throws {
        let store = ShelfStore(storageURL: tempDir.appendingPathComponent("shelf-folder.json"))
        let dir = try makeTestDirectory(named: "bundle", withTree: ["sub/", "sub/inner.txt", "top.txt"])

        let outcome = await store.addBatch([dir])
        XCTAssertEqual(outcome.count, 1, "目录应可挂载")
        XCTAssertTrue(outcome.skipped.isEmpty)

        let items = await store.all()
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].displayName, "bundle")
        XCTAssertEqual(items[0].sourceParentPath, tempDir.path)
        XCTAssertEqual(items[0].fileSize, 0, "文件夹不应展示目录条目元数据大小")
        XCTAssertTrue(items[0].isReachable)

        // 目录内文件真实存在（零拷贝：本体未被改动）
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("sub/inner.txt").path))
    }

    /// 符号链接：指向存在目标的链接可挂载，displayName 用链接自身名称，大小取目标文件大小
    func testSymbolicLinkMount() async throws {
        let store = ShelfStore(storageURL: tempDir.appendingPathComponent("shelf-symlink.json"))
        let target = try makeTestFile(named: "real-target.txt", content: String(repeating: "x", count: 100))
        let link = tempDir.appendingPathComponent("alias.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let outcome = await store.addBatch([link])
        XCTAssertEqual(outcome.count, 1, "指向有效目标的符号链接应可挂载")
        XCTAssertTrue(outcome.skipped.isEmpty)

        let items = await store.all()
        XCTAssertEqual(items[0].displayName, "alias.txt", "displayName 应用链接自身名称")
        XCTAssertEqual(items[0].sourceParentPath, tempDir.path)
        XCTAssertEqual(items[0].fileSize, 100)
        XCTAssertTrue(items[0].isReachable)
    }

    /// 悬空符号链接：链接本体存在，可挂载（不静默丢弃），但目标不可达 → isReachable 为 false
    func testDanglingSymbolicLinkMountsButUnreachable() async throws {
        let store = ShelfStore(storageURL: tempDir.appendingPathComponent("shelf-dangling.json"))
        let link = tempDir.appendingPathComponent("ghost.txt")
        let missing = tempDir.appendingPathComponent("gone.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: missing)

        let outcome = await store.addBatch([link])
        XCTAssertEqual(outcome.count, 1, "链接本体存在，应挂载链接本身而非静默丢弃")
        XCTAssertTrue(outcome.skipped.isEmpty)

        let items = await store.all()
        XCTAssertEqual(items[0].displayName, "ghost.txt")
        XCTAssertEqual(items[0].fileSize, 0, "悬空链接无法解析目标大小")
        XCTAssertFalse(items[0].isReachable, "目标不存在，链接不可达")
    }

    /// 失效检测：源文件被外部移动后，旧路径 isReachable 变 false，新路径可达
    func testReachabilityDetectsMovedSource() async throws {
        let store = ShelfStore(storageURL: tempDir.appendingPathComponent("shelf-moved.json"))
        let file = try makeTestFile(named: "move-me.txt")
        _ = await store.addBatch([file])
        let items = await store.all()
        XCTAssertTrue(items[0].isReachable)

        let movedTo = tempDir.appendingPathComponent("relocated/move-me.txt")
        try FileManager.default.createDirectory(at: movedTo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: file, to: movedTo)

        XCTAssertFalse(items[0].isReachable, "旧路径移动后应不可达")
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedTo.path), "新路径应可达")
    }

    /// 性能：批量挂载 100 个文件，总耗时 < 1.5s（Spike 3.3 通过标准）
    func testBatchMount100FilesUnder1500ms() async throws {
        let store = ShelfStore(storageURL: tempDir.appendingPathComponent("shelf-perf.json"))
        let fileDir = tempDir.appendingPathComponent("bulk", isDirectory: true)
        try FileManager.default.createDirectory(at: fileDir, withIntermediateDirectories: true)
        let urls = try (0..<100).map { i in
            let url = fileDir.appendingPathComponent(String(format: "f%03d.bin", i))
            try Data(repeating: UInt8(i % 256), count: 4096).write(to: url)
            return url
        }

        let outcome = await store.addBatch(urls)
        XCTAssertEqual(outcome.count, 100)
        XCTAssertTrue(outcome.skipped.isEmpty)
        let total = await store.count
        XCTAssertEqual(total, 100)
        XCTAssertLessThan(outcome.elapsed, 1.5, "100 文件挂载应远低于 1.5s，实际 \(outcome.elapsed)s")
        print("[ShelfStoreTests] 100 文件挂载耗时: \(String(format: "%.3f", outcome.elapsed))s")
    }

    /// 无权限文件（chmod 000）：挂载不崩溃；元数据 stat 不需读权限，应能正常挂载
    func testMountPermissionDeniedFileDoesNotCrash() async throws {
        let store = ShelfStore(storageURL: tempDir.appendingPathComponent("shelf-noperm.json"))
        let file = try makeTestFile(named: "locked.txt")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)

        let outcome = await store.addBatch([file])
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)

        XCTAssertEqual(outcome.count, 1, "chmod 000 的文件仅需父目录搜索权限即可读取元数据，应可挂载")
        XCTAssertTrue(outcome.skipped.isEmpty)

        let items = await store.all()
        XCTAssertEqual(items.first?.displayName, "locked.txt")
        XCTAssertTrue(items.first?.isReachable ?? false)
    }

    // MARK: - 体验增强（技术设计细化 2026-08-11）

    /// 清空货架：只移除引用，源文件不受影响（零拷贝模型验证）
    func testClearAllRemovesReferencesButKeepsSourceFiles() async throws {
        let store = ShelfStore(storageURL: tempDir.appendingPathComponent("shelf-clear.json"))
        let file = try makeTestFile(named: "keep-me.txt", content: "survive")
        _ = await store.addBatch([file])

        await store.removeAll()

        let after = await store.all()
        XCTAssertEqual(after.count, 0, "清空后货架应为空")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "清空不得删除源文件")
        XCTAssertEqual(try Data(contentsOf: file), Data("survive".utf8), "源文件内容不受影响")
    }

    /// 清理失效：只移除不可达条目，可达条目保留
    func testRemoveUnreachableOnlyRemovesDeadItems() async throws {
        let store = ShelfStore(storageURL: tempDir.appendingPathComponent("shelf-cleanup.json"))
        let alive = try makeTestFile(named: "alive.txt", content: "alive")
        let dead = try makeTestFile(named: "dead.txt", content: "dead")
        _ = await store.addBatch([alive, dead])

        // 删除 dead 的源文件 → 该条目失效
        try FileManager.default.removeItem(at: dead)
        let deadCount = await store.unreachableCount()
        XCTAssertEqual(deadCount, 1, "应检测到 1 个失效条目")

        let removed = await store.removeUnreachable()
        XCTAssertEqual(removed, 1, "应清理 1 个失效条目")

        let after = await store.all()
        XCTAssertEqual(after.count, 1, "可达条目应保留")
        XCTAssertEqual(after.first?.displayName, "alive.txt")
    }

    /// 无失效条目时清理应返回 0 且不误删
    func testRemoveUnreachableWithNoDeadItems() async throws {
        let store = ShelfStore(storageURL: tempDir.appendingPathComponent("shelf-cleanup2.json"))
        let alive = try makeTestFile(named: "alive2.txt", content: "alive2")
        _ = await store.addBatch([alive])

        let deadCount = await store.unreachableCount()
        XCTAssertEqual(deadCount, 0)
        let removed = await store.removeUnreachable()
        XCTAssertEqual(removed, 0)
        let count = await store.count
        XCTAssertEqual(count, 1, "无失效条目时不应误删")
    }

    // MARK: - 设置页「清除所有货架」（V2-3）

    /// 设置页流程：独立 ShelfStore 实例需先 load() 才能看到已落盘的条目；
    /// removeAll 后货架空且源文件完好（零拷贝模型验证）
    func testFreshStoreLoadThenRemoveAllKeepsSourceFiles() async throws {
        let storeURL = tempDir.appendingPathComponent("shelf-settings-clear.json")
        let writer = ShelfStore(storageURL: storeURL)
        let file1 = try makeTestFile(named: "settings1.txt")
        let file2 = try makeTestFile(named: "settings2.txt")
        _ = await writer.addBatch([file1, file2])

        let settingsStore = ShelfStore(storageURL: storeURL)
        await settingsStore.load()
        let loadedCount = await settingsStore.count
        XCTAssertEqual(loadedCount, 2, "设置页的独立 store 应先 load() 才能读到已落盘条目")

        await settingsStore.removeAll()
        let after = await settingsStore.all()
        XCTAssertEqual(after.count, 0, "清除后货架应为空")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file1.path), "清除不得删除源文件")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file2.path), "清除不得删除源文件")
        XCTAssertEqual(try Data(contentsOf: file1), Data("hello".utf8), "源文件内容不受影响")
    }

    // MARK: - 多货架（V2-4）

    /// 构造一个多货架模式的 store（传目录路径），load() 后返回
    private func makeMultiStore() async -> ShelfStore {
        let baseDir = tempDir.appendingPathComponent("multi-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let store = ShelfStore(storageURL: baseDir)
        await store.load()
        return store
    }

    /// 数据迁移：旧版 shelf.json（V1/V2-M1 单货架数据）首次启动自动迁移为「默认货架」，
    /// 条目数一致；迁移成功后旧文件删除，新模型 shelf-<id>.json 存在；重启后数据保持。
    func testLegacyShelfJsonMigratesToDefaultShelf() async throws {
        let baseDir = tempDir.appendingPathComponent("migrate", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let f1 = try makeTestFile(named: "mig1.txt", content: "mig1")
        let f2 = try makeTestFile(named: "mig2.txt", content: "mig2")

        // 旧版单文件模式写入 shelf.json（V1/V2-M1 存储格式）
        let legacy = ShelfStore(storageURL: baseDir.appendingPathComponent("shelf.json"))
        _ = await legacy.addBatch([f1, f2])

        // 升级：多货架 store（传目录）
        let upgraded = ShelfStore(storageURL: baseDir)
        await upgraded.load()

        let shelves = await upgraded.shelves()
        XCTAssertEqual(shelves.count, 1, "迁移后应有 1 个默认货架")
        XCTAssertEqual(shelves.first?.name, ShelfStore.defaultShelfName, "迁移后货架命名为「默认货架」")
        let migratedCount = await upgraded.count
        XCTAssertEqual(migratedCount, 2, "迁移后条目数应一致")
        let migratedNames = await upgraded.all().map(\.displayName).sorted()
        XCTAssertEqual(migratedNames, ["mig1.txt", "mig2.txt"])

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: baseDir.appendingPathComponent("shelf.json").path),
            "迁移成功后旧 shelf.json 应删除"
        )
        let firstID = try XCTUnwrap(shelves.first?.id)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: baseDir.appendingPathComponent("shelf-\(firstID.uuidString).json").path),
            "新模型 shelf-<id>.json 应存在"
        )

        // 重启保持：新 store 从新模型恢复，不再回退旧格式
        let reloaded = ShelfStore(storageURL: baseDir)
        await reloaded.load()
        let reloadedName = await reloaded.shelves().first?.name
        XCTAssertEqual(reloadedName, ShelfStore.defaultShelfName)
        let reloadedCount = await reloaded.count
        XCTAssertEqual(reloadedCount, 2)
        let reloadedNames = await reloaded.all().map(\.displayName).sorted()
        XCTAssertEqual(reloadedNames, ["mig1.txt", "mig2.txt"])
    }

    /// 多货架隔离：A 货架 addBatch 不影响 B；切换后各货架条目独立
    func testMultiShelfIsolation() async throws {
        let store = await makeMultiStore()
        let current = await store.currentShelf()
        let defaultID = try XCTUnwrap(current?.id)
        let createdA = await store.createShelf(name: "项目A")
        let shelfA = try XCTUnwrap(createdA)
        let currentAfterCreate = await store.currentShelf()
        XCTAssertEqual(currentAfterCreate?.name, "项目A", "新建货架应成为当前货架")

        let fa = try makeTestFile(named: "iso-a.txt", content: "a")
        _ = await store.addBatch([fa])
        let countA = await store.count
        XCTAssertEqual(countA, 1, "A 货架应有 1 条")

        await store.selectShelf(id: defaultID)
        let defaultCount = await store.count
        XCTAssertEqual(defaultCount, 0, "默认货架不应受 A 货架影响")
        let fb = try makeTestFile(named: "iso-b.txt", content: "b")
        _ = await store.addBatch([fb])
        let defaultCount2 = await store.count
        XCTAssertEqual(defaultCount2, 1)

        await store.selectShelf(id: shelfA)
        let countA2 = await store.count
        XCTAssertEqual(countA2, 1, "切回 A 仍只有自己的 1 条")
        let namesInA = await store.all().map(\.displayName)
        XCTAssertEqual(namesInA.first, "iso-a.txt")
        XCTAssertFalse(namesInA.contains("iso-b.txt"), "B 的条目不应出现在 A")
    }

    /// 默认货架存在性保证：至少一个货架，不允许删除最后一个
    func testCannotDeleteLastShelf() async throws {
        let store = await makeMultiStore()
        let currentShelf = await store.currentShelf()
        let id = try XCTUnwrap(currentShelf?.id)
        let shelfCount = await store.shelves().count
        XCTAssertEqual(shelfCount, 1)

        let deleted = await store.deleteShelf(id: id)
        XCTAssertFalse(deleted, "最后一个货架不允许删除")
        let after = await store.shelves().count
        XCTAssertEqual(after, 1)
        let currentAfter = await store.currentShelf()
        XCTAssertEqual(currentAfter?.id, id, "删除被拒后当前货架不变")
    }

    /// 新建 / 重命名 / 删除货架（非最后一个）
    func testCreateRenameDeleteShelf() async throws {
        let store = await makeMultiStore()
        let current = await store.currentShelf()
        let defaultID = try XCTUnwrap(current?.id)

        let createdNew = await store.createShelf(name: "  项目A  ")
        let newID = try XCTUnwrap(createdNew)
        let shelfCount = await store.shelves().count
        XCTAssertEqual(shelfCount, 2)
        let currentAfterCreate = await store.currentShelf()
        XCTAssertEqual(currentAfterCreate?.name, "项目A", "名称应去除首尾空白")

        await store.renameShelf(id: newID, name: "项目B")
        let renamedMeta = await store.shelves().first(where: { $0.id == newID })
        XCTAssertEqual(renamedMeta?.name, "项目B")
        let currentAfterRename = await store.currentShelf()
        XCTAssertEqual(currentAfterRename?.name, "项目B", "重命名当前货架后名称同步")

        let deleted = await store.deleteShelf(id: newID)
        XCTAssertTrue(deleted, "非最后一个货架应可删除")
        let after = await store.shelves().count
        XCTAssertEqual(after, 1)
        let currentAfterDelete = await store.currentShelf()
        XCTAssertEqual(currentAfterDelete?.id, defaultID, "删除当前货架后应回落到默认货架")
    }

    /// 设置页「清除所有货架」联动：遍历清空全部货架的条目，保留货架本身；源文件不受影响
    func testClearAllShelvesClearsItemsButKeepsShelves() async throws {
        let store = await makeMultiStore()
        let current = await store.currentShelf()
        let defaultID = try XCTUnwrap(current?.id)
        let createdA = await store.createShelf(name: "项目A")
        let shelfA = try XCTUnwrap(createdA)

        let fa = try makeTestFile(named: "clear-a.txt", content: "a")
        _ = await store.addBatch([fa])
        await store.selectShelf(id: defaultID)
        let fb = try makeTestFile(named: "clear-b.txt", content: "b")
        _ = await store.addBatch([fb])
        let totalBefore = await store.totalItemCount
        XCTAssertEqual(totalBefore, 2, "两个货架共 2 条")

        await store.clearAllShelves()

        let shelfCountAfter = await store.shelves().count
        XCTAssertEqual(shelfCountAfter, 2, "清空所有货架应保留货架本身")
        let countNow = await store.count
        XCTAssertEqual(countNow, 0)
        await store.selectShelf(id: shelfA)
        let countA = await store.count
        XCTAssertEqual(countA, 0, "另一货架条目也应清空")
        let totalAfter = await store.totalItemCount
        XCTAssertEqual(totalAfter, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fa.path), "清空不得删除源文件")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fb.path), "清空不得删除源文件")
    }

    /// 空名新建回退默认名；空 registry 不存在时全新安装也保证至少一个默认货架
    func testEmptyNameFallsBackToDefaultAndFreshInstallHasDefaultShelf() async throws {
        let baseDir = tempDir.appendingPathComponent("fresh", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let store = ShelfStore(storageURL: baseDir)
        await store.load()

        let shelfCount = await store.shelves().count
        XCTAssertEqual(shelfCount, 1, "全新安装应创建默认货架")
        let current = await store.currentShelf()
        XCTAssertEqual(current?.name, ShelfStore.defaultShelfName)

        let createdEmpty = await store.createShelf(name: "   ")
        let id = try XCTUnwrap(createdEmpty)
        let currentAfter = await store.currentShelf()
        XCTAssertEqual(currentAfter?.id, id)
        XCTAssertEqual(currentAfter?.name, ShelfStore.defaultShelfName, "空名应回退默认名")
    }
}
