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
}
