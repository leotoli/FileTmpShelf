import XCTest
@testable import FileTmpShelf

/// V2-6：排序 / 置顶 / 批量移除 / 多货架各自顺序独立。
final class ShelfOrderingTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShelfOrderingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeFiles() throws -> [URL] {
        try (0..<5).map { i in
            let url = tempDir.appendingPathComponent("f\(i).txt")
            try Data("f\(i)".utf8).write(to: url)
            return url
        }
    }

    /// 单文件模式 store，挂载 f0...f4，返回 (store, storageURL, items)
    private func makeOrderedStore() async throws -> (ShelfStore, URL, [ShelfItem]) {
        let url = tempDir.appendingPathComponent("order-\(UUID().uuidString).json")
        let store = ShelfStore(storageURL: url)
        _ = await store.addBatch(try makeFiles())
        return (store, url, await store.all())
    }

    private func names(_ items: [ShelfItem]) -> [String] {
        items.map(\.displayName)
    }

    private func currentNames(_ store: ShelfStore) async -> [String] {
        names(await store.all())
    }

    private func assertOrder(_ store: ShelfStore, _ expected: [String], file: StaticString = #filePath, line: UInt = #line) async {
        let actual = await currentNames(store)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    // MARK: - moveItem(from:to:)

    /// 移动到目标之前：f2 移到 f0 前 → [f2,f0,f1,f3,f4]
    func testMoveItemPlacesBeforeDestination() async throws {
        let (store, url, items) = try await makeOrderedStore()
        await store.moveItem(from: items[2].id, to: items[0].id)
        await assertOrder(store, ["f2.txt", "f0.txt", "f1.txt", "f3.txt", "f4.txt"])

        // 重启后顺序保持（顺序持久化 round-trip）
        let reloaded = ShelfStore(storageURL: url)
        await reloaded.load()
        await assertOrder(reloaded, ["f2.txt", "f0.txt", "f1.txt", "f3.txt", "f4.txt"])
    }

    /// 向下移（f0 移到 f3 前 → [f1,f2,f0,f3,f4]）
    func testMoveItemBeforeDestinationDownward() async throws {
        let (store, _, items) = try await makeOrderedStore()
        await store.moveItem(from: items[0].id, to: items[3].id)
        await assertOrder(store, ["f1.txt", "f2.txt", "f0.txt", "f3.txt", "f4.txt"])
    }

    /// 相同 id / 不存在的 id → no-op
    func testMoveItemNoOp() async throws {
        let (store, _, items) = try await makeOrderedStore()
        await store.moveItem(from: items[0].id, to: items[0].id)
        await store.moveItem(from: UUID(), to: items[0].id)
        await store.moveItem(from: items[0].id, to: UUID())
        await assertOrder(store, ["f0.txt", "f1.txt", "f2.txt", "f3.txt", "f4.txt"])
    }

    // MARK: - moveItem(from:toIndex:)

    /// 目标下标 = 移动完成后条目所在位置：f0 → index 3 → [f1,f2,f3,f0,f4]
    /// 注：toIndex 变体是拖拽 drop 实时反馈用（不落盘），drop 结束由 reorder(by:) 一次性提交，
    /// 这里只断言内存顺序；持久化 round-trip 由 reorder(by:) 测试覆盖。
    func testMoveItemToIndexEndsAtTarget() async throws {
        let (store, _, items) = try await makeOrderedStore()
        await store.moveItem(from: items[0].id, toIndex: 3)
        await assertOrder(store, ["f1.txt", "f2.txt", "f3.txt", "f0.txt", "f4.txt"])
    }

    /// 向上移：f4 → index 1 → [f0,f4,f1,f2,f3]
    func testMoveItemToIndexUpward() async throws {
        let (store, _, items) = try await makeOrderedStore()
        await store.moveItem(from: items[4].id, toIndex: 1)
        await assertOrder(store, ["f0.txt", "f4.txt", "f1.txt", "f2.txt", "f3.txt"])
    }

    // MARK: - pin

    /// 置顶单个：f4 → [f4,f0,f1,f2,f3]，重启保持
    func testPinMovesToTopAndPersists() async throws {
        let (store, url, items) = try await makeOrderedStore()
        await store.pin(id: items[4].id)
        await assertOrder(store, ["f4.txt", "f0.txt", "f1.txt", "f2.txt", "f3.txt"])

        let reloaded = ShelfStore(storageURL: url)
        await reloaded.load()
        await assertOrder(reloaded, ["f4.txt", "f0.txt", "f1.txt", "f2.txt", "f3.txt"])
    }

    /// 置顶一组：保持条目原有相对顺序拼到头部 → [f0,f2,f1,f3,f4]（f0 在 f2 前，与原序一致）
    func testPinGroupPreservesRelativeOrder() async throws {
        let (store, _, items) = try await makeOrderedStore()
        await store.pin(ids: [items[2].id, items[0].id])
        await assertOrder(store, ["f0.txt", "f2.txt", "f1.txt", "f3.txt", "f4.txt"])
    }

    /// 全部条目都在置顶集中 / 置顶集中无当前条目 → no-op 不重复写盘
    func testPinNoOp() async throws {
        let (store, _, items) = try await makeOrderedStore()
        await store.pin(ids: [UUID()])
        await store.pin(ids: Set(items.map(\.id)))
        await assertOrder(store, ["f0.txt", "f1.txt", "f2.txt", "f3.txt", "f4.txt"])
    }

    // MARK: - reorder(by:)

    /// 按 id 列表整体重排并持久化
    func testReorderByIDsPersists() async throws {
        let (store, url, items) = try await makeOrderedStore()
        let order = [items[4].id, items[0].id, items[3].id, items[1].id, items[2].id]
        await store.reorder(by: order)
        await assertOrder(store, ["f4.txt", "f0.txt", "f3.txt", "f1.txt", "f2.txt"])

        let reloaded = ShelfStore(storageURL: url)
        await reloaded.load()
        await assertOrder(reloaded, ["f4.txt", "f0.txt", "f3.txt", "f1.txt", "f2.txt"])
    }

    /// 未知 id 忽略、缺失条目追加末尾
    func testReorderByIDsToleratesUnknownAndMissing() async throws {
        let (store, _, items) = try await makeOrderedStore()
        // 只给 [f2, 未知]：f2 打头，其余按原序追加
        await store.reorder(by: [items[2].id, UUID()])
        await assertOrder(store, ["f2.txt", "f0.txt", "f1.txt", "f3.txt", "f4.txt"])
    }

    // MARK: - remove(ids:)

    /// 批量移除多条一次持久化；幂等：重复移除不报错
    func testRemoveBatch() async throws {
        let (store, url, items) = try await makeOrderedStore()
        await store.remove(ids: [items[0].id, items[2].id])
        await assertOrder(store, ["f1.txt", "f3.txt", "f4.txt"])

        // 幂等：重复移除已删除的 id 不报错、不改变结果
        await store.remove(ids: [items[0].id])
        await assertOrder(store, ["f1.txt", "f3.txt", "f4.txt"])

        let reloaded = ShelfStore(storageURL: url)
        await reloaded.load()
        await assertOrder(reloaded, ["f1.txt", "f3.txt", "f4.txt"])
    }

    // MARK: - 多货架各自顺序独立

    /// 两个货架各自 reorder/pin，切换后顺序互不影响（shelf-<id>.json 独立持久化）
    func testMultiShelfOrderIndependent() async throws {
        let baseDir = tempDir.appendingPathComponent("multi-order-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        let store = ShelfStore(storageURL: baseDir)
        await store.load()

        // 默认货架 id 先记录（createShelf 会切换当前货架）
        let defaultShelf = await store.currentShelf()
        let defaultID = try XCTUnwrap(defaultShelf?.id)

        // A 货架挂 f0...f4，置顶 f4
        let createdShelfA = await store.createShelf(name: "A")
        let shelfA = try XCTUnwrap(createdShelfA)
        XCTAssertNotEqual(defaultID, shelfA)
        _ = await store.addBatch(try makeFiles())
        let aItems = await store.all()
        await store.pin(id: aItems[4].id)
        await assertOrder(store, ["f4.txt", "f0.txt", "f1.txt", "f2.txt", "f3.txt"])

        // 默认货架挂 f0...f4，只重排 f1 到 f3 前（不同顺序，persist 变体保证落盘）
        await store.selectShelf(id: defaultID)
        _ = await store.addBatch(try makeFiles())
        let dItems = await store.all()
        await store.moveItem(from: dItems[1].id, to: dItems[3].id)
        await assertOrder(store, ["f0.txt", "f2.txt", "f1.txt", "f3.txt", "f4.txt"])

        // 切回 A：顺序仍为 A 自己的置顶顺序，不受默认货架重排影响
        await store.selectShelf(id: shelfA)
        await assertOrder(store, ["f4.txt", "f0.txt", "f1.txt", "f2.txt", "f3.txt"])

        // 再切回默认：仍保持默认货架的移动顺序
        await store.selectShelf(id: defaultID)
        await assertOrder(store, ["f0.txt", "f2.txt", "f1.txt", "f3.txt", "f4.txt"])

        // 重启后两货架顺序各自保持
        let reloaded = ShelfStore(storageURL: baseDir)
        await reloaded.load()
        await reloaded.selectShelf(id: shelfA)
        await assertOrder(reloaded, ["f4.txt", "f0.txt", "f1.txt", "f2.txt", "f3.txt"])
        await reloaded.selectShelf(id: defaultID)
        await assertOrder(reloaded, ["f0.txt", "f2.txt", "f1.txt", "f3.txt", "f4.txt"])
    }
}
