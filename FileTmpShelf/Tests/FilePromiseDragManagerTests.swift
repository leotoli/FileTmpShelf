import XCTest
@testable import FileTmpShelf

/// Spike S2 — FilePromiseDragManager 移动核心单测。
/// NSFilePromiseProvider 的 Finder 兑现回调（writePromiseToURL）依赖真实拖拽会话，
/// 无法在单元测试中触发，因此这里只测 manager 层逻辑（moveAndNotify / performMove）：
/// 成功路径（源消失、目标出现、内容一致）、失败路径（数据零丢失：源保留、回调不触发移除）、
/// fileNameForType / fileType 映射、provider 强持有 delegate。
@MainActor
final class FilePromiseDragManagerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FilePromiseDragManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeItem(named name: String, content: String = "s2-payload") throws -> (ShelfItem, URL) {
        let url = tempDir.appendingPathComponent(name)
        try Data(content.utf8).write(to: url)
        guard let item = ShelfItem.make(from: url) else {
            throw XCTSkip("无法构造 ShelfItem（\(name)），跳过本用例")
        }
        return (item, url)
    }

    private func moveAndNotify(
        _ manager: FilePromiseDragManager,
        to url: URL
    ) -> Result<Void, Error> {
        let exp = expectation(description: "moveAndNotify(\(url.lastPathComponent))")
        var captured: Result<Void, Error>?
        manager.moveAndNotify(to: url) { error in
            captured = error.map(Result<Void, Error>.failure) ?? .success(())
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        return captured ?? .failure(FilePromiseDragManagerTestsError.noResult)
    }

    private enum FilePromiseDragManagerTestsError: Error {
        case noResult
    }

    // MARK: - 成功路径

    /// 移动成功：源文件消失、目标文件存在且内容一致
    func testMoveSuccessRemovesSourceAndCreatesDestination() throws {
        let (item, source) = try makeItem(named: "move.txt", content: "hello-s2")
        let destDir = tempDir.appendingPathComponent("dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent("move.txt")

        let manager = FilePromiseDragManager(item: item) { _ in }
        let result = moveAndNotify(manager, to: dest)

        XCTAssertNoThrow(try result.get(), "正常目录内移动应成功")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "移动成功后源文件应消失")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path), "目标文件应存在")
        XCTAssertEqual(try Data(contentsOf: dest), Data("hello-s2".utf8), "目标内容应与源一致")
    }

    /// 文件夹移动：目录树整体移动成功
    func testMoveSuccessForDirectory() throws {
        let dir = tempDir.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("inner".utf8).write(to: dir.appendingPathComponent("inner.txt"))
        guard let item = ShelfItem.make(from: dir) else {
            throw XCTSkip("无法构造目录 ShelfItem")
        }
        let dest = tempDir.appendingPathComponent("moved-bundle", isDirectory: true)

        let manager = FilePromiseDragManager(item: item) { _ in }
        let result = moveAndNotify(manager, to: dest)

        XCTAssertNoThrow(try result.get())
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "目录移动成功后源应消失")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("inner.txt").path), "目录树应完整迁移")
    }

    /// 移动成功 → completionHandler(nil) + onMoveCompleted 回调触发（携带同一 item），供货架移除条目
    func testMoveSuccessTriggersOnMoveCompleted() throws {
        let (item, _) = try makeItem(named: "callback.txt")
        let dest = tempDir.appendingPathComponent("callback-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let notifyExp = expectation(description: "onMoveCompleted 回调")
        var callbackItem: ShelfItem?
        let manager = FilePromiseDragManager(item: item) { moved in
            callbackItem = moved
            notifyExp.fulfill()
        }

        let completionExp = expectation(description: "completionHandler(nil)")
        manager.moveAndNotify(to: dest.appendingPathComponent("callback.txt")) { error in
            XCTAssertNil(error, "移动成功应回调 nil")
            completionExp.fulfill()
        }
        wait(for: [completionExp, notifyExp], timeout: 5)
        XCTAssertEqual(callbackItem?.id, item.id, "回调应携带被移动的条目，供货架按 id 移除")
    }

    // MARK: - 失败路径（数据零丢失）

    /// 目标目录不存在 → 移动失败 → completionHandler(error) + 源文件保留且内容不变 + 不触发移除回调
    func testMoveFailureWhenDestinationDirectoryMissingKeepsSource() throws {
        let (item, source) = try makeItem(named: "gone-dir.txt", content: "keep-me")
        let dest = tempDir.appendingPathComponent("no-such-dir", isDirectory: true)
            .appendingPathComponent("gone-dir.txt")

        var notifyCount = 0
        let manager = FilePromiseDragManager(item: item) { _ in notifyCount += 1 }
        let result = moveAndNotify(manager, to: dest)

        guard case .failure = result else {
            return XCTFail("目标父目录不存在，移动应失败")
        }
        XCTAssertEqual(notifyCount, 0, "失败路径不应触发货架移除回调（条目回滚保留）")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "失败时源文件必须保留（数据零丢失）")
        XCTAssertEqual(try Data(contentsOf: source), Data("keep-me".utf8), "失败时源内容必须完好")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path), "失败时目标不应存在")
    }

    /// 同名冲突（目标已有同名文件）→ moveItem 失败（.fileWriteFileExists）→ 源保留、目标不被覆盖
    func testMoveFailureOnSameNameConflictKeepsBoth() throws {
        let (item, source) = try makeItem(named: "conflict.txt", content: "source-version")
        let destDir = tempDir.appendingPathComponent("conflict-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent("conflict.txt")
        try Data("existing-version".utf8).write(to: dest)

        var notifyCount = 0
        let manager = FilePromiseDragManager(item: item) { _ in notifyCount += 1 }
        let result = moveAndNotify(manager, to: dest)

        guard case .failure = result else {
            return XCTFail("目标同名已存在，moveItem 应失败（不覆盖）")
        }
        XCTAssertEqual(notifyCount, 0, "失败路径不应触发货架移除回调")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "同名冲突失败时源文件必须保留")
        XCTAssertEqual(try Data(contentsOf: dest), Data("existing-version".utf8), "失败时不得覆盖目标既有文件")
    }

    /// 目标目录无写权限（chmod 000）→ 移动失败 → 源保留
    func testMoveFailureOnPermissionDeniedKeepsSource() throws {
        let (item, source) = try makeItem(named: "locked-dir.txt", content: "permission-payload")
        let destDir = tempDir.appendingPathComponent("readonly", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: destDir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destDir.path)
        }

        var notifyCount = 0
        let manager = FilePromiseDragManager(item: item) { _ in notifyCount += 1 }
        let result = moveAndNotify(manager, to: destDir.appendingPathComponent("locked-dir.txt"))

        guard case .failure = result else {
            return XCTFail("目标目录无写权限，移动应失败")
        }
        XCTAssertEqual(notifyCount, 0, "权限拒绝时不得触发货架移除回调")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "权限拒绝时源文件必须保留（数据零丢失）")
    }

    // MARK: - provider 配置

    /// fileNameForType 返回条目 displayName（Finder 用它生成目标文件名）
    func testFileNameForTypeReturnsDisplayName() throws {
        let (item, _) = try makeItem(named: "photo.png")
        let manager = FilePromiseDragManager(item: item) { _ in }
        let provider = NSFilePromiseProvider(fileType: "public.png", delegate: manager)

        XCTAssertEqual(
            manager.filePromiseProvider(provider, fileNameForType: "public.png"),
            "photo.png"
        )
    }

    /// promiseFileType：普通文件取真实 UTI，文件夹取 public.folder，未知扩展回退 public.data
    func testPromiseFileTypeMapping() throws {
        XCTAssertEqual(
            FilePromiseDragManager.promiseFileType(for: ShelfItem(path: "/tmp/a.txt", displayName: "a.txt", fileSize: 1, sourceParentPath: "/tmp")),
            "public.plain-text"
        )
        XCTAssertEqual(
            FilePromiseDragManager.promiseFileType(for: ShelfItem(path: "/tmp/bundle/", displayName: "bundle", fileSize: 0, sourceParentPath: "/tmp")),
            "public.directory",
            "UTType.directory.identifier 为 public.directory（folder 是旧 kUTTypeFolder 兼容名）"
        )
        XCTAssertEqual(
            FilePromiseDragManager.promiseFileType(for: ShelfItem(path: "/tmp/unknown.xyzzy", displayName: "unknown.xyzzy", fileSize: 1, sourceParentPath: "/tmp")),
            "public.data"
        )
    }

    /// FilePromiseDragManager 可直接作为 NSFilePromiseProvider 的 delegate 使用
    /// （provider.delegate 是 weak，真实运行期由 FilePromiseDragView 强持有 manager）
    func testManagerCanServeAsProviderDelegate() throws {
        let (item, _) = try makeItem(named: "provider.txt")
        let manager = FilePromiseDragManager(item: item) { _ in }
        let provider = NSFilePromiseProvider(
            fileType: FilePromiseDragManager.promiseFileType(for: item),
            delegate: manager
        )

        XCTAssertNotNil(provider.delegate)
        XCTAssertNotEqual(provider.fileType, "public.file-url", "fileType 应为文件真实 UTI（或合适类型），而非 URL 引用类型")
        XCTAssertEqual(
            manager.filePromiseProvider(provider, fileNameForType: provider.fileType),
            "provider.txt",
            "fileNameForType 应返回 displayName，供 Finder 生成目标文件名"
        )
    }
}
