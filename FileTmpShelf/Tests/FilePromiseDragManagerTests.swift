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

    /// 构造"强制跨卷"的 manager：volumeResolver 恒 true 模拟不同卷
    /// （真实跨卷是不同卷 UUID；单测在同一文件系统，volumeIdentifier 相同，需注入模拟）。
    private func makeCrossVolumeManager(
        item: ShelfItem,
        copyVerifier: ((URL, URL) -> Bool)? = nil,
        onMoveCompleted: @escaping (ShelfItem) -> Void = { _ in }
    ) -> FilePromiseDragManager {
        FilePromiseDragManager(
            item: item,
            onMoveCompleted: onMoveCompleted,
            volumeResolver: { _, _ in true },
            copyVerifier: copyVerifier
        )
    }

    /// 构造目录条目（含嵌套子目录，验证递归条目数校验）
    private func makeDirectoryItem(named name: String) throws -> (ShelfItem, URL) {
        let dir = tempDir.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("inner".utf8).write(to: dir.appendingPathComponent("inner.txt"))
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub", isDirectory: true), withIntermediateDirectories: true)
        try Data("deep".utf8).write(to: dir.appendingPathComponent("sub", isDirectory: true).appendingPathComponent("deep.txt"))
        guard let item = ShelfItem.make(from: dir) else {
            throw XCTSkip("无法构造目录 ShelfItem")
        }
        return (item, dir)
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

    // MARK: - V2-5 跨卷路径

    /// 同卷路径不变：volumeResolver 恒 false 强制同卷，copyVerifier 恒 false 做哨兵——
    /// 若误入跨卷复制路径，校验必失败，测试即失败；同卷应直接原子 moveItem 成功。
    func testSameVolumePathUsesAtomicMove() throws {
        let (item, source) = try makeItem(named: "samevol.txt", content: "atomic")
        let destDir = tempDir.appendingPathComponent("samevol-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent("samevol.txt")

        let manager = FilePromiseDragManager(
            item: item,
            onMoveCompleted: { _ in },
            volumeResolver: { _, _ in false },
            copyVerifier: { _, _ in false }
        )
        let result = moveAndNotify(manager, to: dest)

        XCTAssertNoThrow(try result.get(), "同卷应走原子 moveItem 成功（不经 copy/verify）")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "移动成功后源应消失")
        XCTAssertEqual(try Data(contentsOf: dest), Data("atomic".utf8), "目标内容应与源一致")
    }

    /// 跨卷成功：copyItem → 真实校验（文件大小一致）→ 删除源 → completionHandler(nil) + 货架移除回调
    func testCrossVolumeSuccessCopiesVerifiesAndDeletesSource() throws {
        let (item, source) = try makeItem(named: "cross.txt", content: "cross-payload")
        let destDir = tempDir.appendingPathComponent("cross-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent("cross.txt")

        let notifyExp = expectation(description: "跨卷成功触发货架移除回调")
        let manager = makeCrossVolumeManager(item: item, onMoveCompleted: { _ in notifyExp.fulfill() })
        let result = moveAndNotify(manager, to: dest)

        XCTAssertNoThrow(try result.get(), "跨卷移动成功应回调 nil")
        wait(for: [notifyExp], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "校验通过后源应被删除")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path), "目标应存在")
        XCTAssertEqual(try Data(contentsOf: dest), Data("cross-payload".utf8), "目标内容应与源一致")
    }

    /// 跨卷校验失败：源保留（数据零丢失）+ 不完整目标被清理 + completionHandler(error) + 不触发移除回调
    func testCrossVolumeVerificationFailureKeepsSourceAndCleansDestination() throws {
        let (item, source) = try makeItem(named: "verify-fail.txt", content: "must-keep")
        let destDir = tempDir.appendingPathComponent("verify-fail-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent("verify-fail.txt")

        var notifyCount = 0
        // copyVerifier 恒 false：模拟"复制完成后校验发现目标不完整"
        let manager = makeCrossVolumeManager(
            item: item,
            copyVerifier: { _, _ in false },
            onMoveCompleted: { _ in notifyCount += 1 }
        )
        let result = moveAndNotify(manager, to: dest)

        guard case .failure(let error) = result else {
            return XCTFail("校验失败应返回 error")
        }
        XCTAssertTrue(error is FilePromiseDragManager.FilePromiseMoveError, "应返回跨卷移动错误类型，实际: \(error)")
        XCTAssertEqual(notifyCount, 0, "校验失败不得触发货架移除回调（条目回滚保留）")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "校验失败必须保留源（数据零丢失）")
        XCTAssertEqual(try Data(contentsOf: source), Data("must-keep".utf8), "失败时源内容必须完好")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path), "不完整目标应被尽力清理")
    }

    /// 跨卷复制失败（目标父目录不存在）：源保留 + 目标无残留 + completionHandler(error)
    func testCrossVolumeCopyFailureKeepsSource() throws {
        let (item, source) = try makeItem(named: "copy-fail.txt", content: "safe")
        let dest = tempDir.appendingPathComponent("no-such-dir", isDirectory: true)
            .appendingPathComponent("copy-fail.txt")

        var notifyCount = 0
        let manager = makeCrossVolumeManager(item: item) { _ in notifyCount += 1 }
        let result = moveAndNotify(manager, to: dest)

        guard case .failure = result else {
            return XCTFail("目标父目录不存在，跨卷复制应失败")
        }
        XCTAssertEqual(notifyCount, 0, "复制失败不得触发货架移除回调")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "复制失败源必须保留（数据零丢失）")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path), "复制失败目标不应残留")
    }

    /// 目录跨卷成功：真实校验按"递归条目数一致"通过 → 删源，目录树完整迁移
    func testCrossVolumeDirectorySuccessVerifiesItemCount() throws {
        let (item, dir) = try makeDirectoryItem(named: "bundle-cross")
        let dest = tempDir.appendingPathComponent("bundle-cross-moved", isDirectory: true)

        let manager = makeCrossVolumeManager(item: item)
        let result = moveAndNotify(manager, to: dest)

        XCTAssertNoThrow(try result.get(), "目录跨卷复制+校验应成功")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "校验通过后目录源应被删除")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("inner.txt").path), "目录树应完整迁移")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("sub", isDirectory: true).appendingPathComponent("deep.txt").path))
    }

    /// 目录跨卷校验失败（注入假校验）：源保留 + 不完整目录目标被清理 + error
    func testCrossVolumeDirectoryVerificationFailureKeepsSource() throws {
        let (item, dir) = try makeDirectoryItem(named: "bundle-verify-fail")
        let dest = tempDir.appendingPathComponent("bundle-verify-fail-moved", isDirectory: true)

        var notifyCount = 0
        let manager = makeCrossVolumeManager(
            item: item,
            copyVerifier: { _, _ in false },
            onMoveCompleted: { _ in notifyCount += 1 }
        )
        let result = moveAndNotify(manager, to: dest)

        guard case .failure = result else {
            return XCTFail("目录校验失败应返回 error")
        }
        XCTAssertEqual(notifyCount, 0, "目录校验失败不得触发货架移除回调")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path), "目录校验失败源必须保留（数据零丢失）")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path), "不完整目录目标应被清理")
    }

    /// 真实卷判定（不注入 volumeResolver）：同一临时目录内移动应被 `volumeIdentifier`
    /// 判为同卷 → 走原子 moveItem；copyVerifier 哨兵恒 false，若误判为跨卷必失败。
    func testRealVolumeDetectionTreatsTempDirAsSameVolume() throws {
        let (item, source) = try makeItem(named: "realvol.txt", content: "same-disk")
        let destDir = tempDir.appendingPathComponent("realvol-dest", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let dest = destDir.appendingPathComponent("realvol.txt")

        let manager = FilePromiseDragManager(
            item: item,
            onMoveCompleted: { _ in },
            copyVerifier: { _, _ in false }
        )
        let result = moveAndNotify(manager, to: dest)

        XCTAssertNoThrow(try result.get(), "同盘移动应判同卷并成功（未走跨卷复制）")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "移动成功后源应消失")
        XCTAssertEqual(try Data(contentsOf: dest), Data("same-disk".utf8), "目标内容应与源一致")
    }

    // MARK: - V2-5 校验逻辑（verifyCopy 直测）

    /// 文件校验：目标缺失 -> 失败；大小一致 -> 通过；大小不一致（模拟复制中断残留）-> 失败
    func testVerifyCopyFileBySize() throws {
        let src = tempDir.appendingPathComponent("v-src.bin")
        let dst = tempDir.appendingPathComponent("v-dst.bin")
        try Data(repeating: 0xAB, count: 4096).write(to: src)

        let (dummy, _) = try makeItem(named: "x.txt")
        let manager = FilePromiseDragManager(item: dummy) { _ in }

        XCTAssertFalse(
            manager.verifyCopy(source: src, destination: tempDir.appendingPathComponent("missing.bin")),
            "目标缺失应判校验失败"
        )

        try Data(repeating: 0xAB, count: 4096).write(to: dst)
        XCTAssertTrue(manager.verifyCopy(source: src, destination: dst), "大小一致应判通过")

        try Data(repeating: 0xAB, count: 4095).write(to: dst, options: .atomic)
        XCTAssertFalse(manager.verifyCopy(source: src, destination: dst), "大小不一致应判校验失败")
    }

    /// 目录校验：递归条目数一致 -> 通过；目标缺条目（模拟复制中断）-> 失败；目标缺失 -> 失败
    func testVerifyCopyDirectoryByItemCount() throws {
        let srcDir = tempDir.appendingPathComponent("vdir-src", isDirectory: true)
        let dstDir = tempDir.appendingPathComponent("vdir-dst", isDirectory: true)
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: srcDir.appendingPathComponent("a.txt"))
        try FileManager.default.createDirectory(at: srcDir.appendingPathComponent("sub", isDirectory: true), withIntermediateDirectories: true)
        try Data("b".utf8).write(to: srcDir.appendingPathComponent("sub", isDirectory: true).appendingPathComponent("b.txt"))

        let (dummy, _) = try makeItem(named: "x.txt")
        let manager = FilePromiseDragManager(item: dummy) { _ in }

        try FileManager.default.copyItem(at: srcDir, to: dstDir)
        XCTAssertTrue(manager.verifyCopy(source: srcDir, destination: dstDir), "完整复制条目数一致应判通过")

        // 模拟复制中断：目标缺失 sub/b.txt（条目数不一致）
        try FileManager.default.removeItem(at: dstDir.appendingPathComponent("sub", isDirectory: true).appendingPathComponent("b.txt"))
        XCTAssertFalse(manager.verifyCopy(source: srcDir, destination: dstDir), "目标缺条目应判校验失败")

        XCTAssertFalse(
            manager.verifyCopy(source: srcDir, destination: tempDir.appendingPathComponent("no-vdir-dst", isDirectory: true)),
            "目标缺失应判校验失败"
        )
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

/// CombinedFilePromiseWriter：一次拖拽同时提供 file promise（Finder）+ 真实文件 URL
/// （微信/iTerm2 等非 promise 目标）——修复"拖到微信/终端根本没出现文件"。
@MainActor
final class CombinedFilePromiseWriterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CombinedWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeWriter(named name: String) throws -> (CombinedFilePromiseWriter, URL) {
        let url = tempDir.appendingPathComponent(name)
        try Data("payload".utf8).write(to: url)
        guard let item = ShelfItem.make(from: url) else {
            throw XCTSkip("无法构造 ShelfItem")
        }
        let manager = FilePromiseDragManager(item: item) { _ in }
        let provider = NSFilePromiseProvider(
            fileType: FilePromiseDragManager.promiseFileType(for: item),
            delegate: manager
        )
        return (CombinedFilePromiseWriter(promise: provider, fileURL: item.fileURL), url)
    }

    /// writableTypes 同时含 promise 类型与 public.file-url（微信/iTerm2 需要的）
    func testWritableTypesIncludeFileURLAndPromise() throws {
        let (writer, _) = try makeWriter(named: "combined.pdf")
        let types = writer.writableTypes(for: NSPasteboard(name: .general))

        XCTAssertTrue(types.contains(.fileURL), "应注册 public.file-url 供微信/终端读取")
        // promise 类型：fileURL 是后加的，原生类型应保留（pboard 类型含 promised/dyn 或原 UTI）
        XCTAssertTrue(types.count >= 2, "应同时有 promise 类型与 fileURL，实际: \(types)")
    }

    /// fileURL 类型的 pasteboard 值为源文件路径字符串（微信/iTerm2 可直接读）
    func testFileURLPropertyListIsPath() throws {
        let (writer, url) = try makeWriter(named: "combined.txt")
        let value = writer.pasteboardPropertyList(forType: .fileURL)

        XCTAssertEqual(value as? String, url.path, "public.file-url 应返回文件路径字符串")
    }

    /// 非 fileURL 类型（promise 类型）委托给内部 provider，不崩溃且返回有效数据
    func testPromiseTypesDelegateToProvider() throws {
        let (writer, _) = try makeWriter(named: "combined.bin")
        let provider = writer.promise
        // provider 原生声明的前 N 个类型应能通过包装 writer 取到（不为 nil 或可懒加载）
        let providerTypes = provider.writableTypes(for: NSPasteboard(name: .general))
        let first = providerTypes.first
        if let first {
            // 要么直接有值，要么进入懒加载兜底不崩溃（数据由 pasteboard(_:item:provideDataForType:) 提供）
            _ = writer.pasteboardPropertyList(forType: first)
        }
        XCTAssertGreaterThan(providerTypes.count, 0, "provider 应声明至少一个 promise 类型")
    }

    /// didCompleteMove 初始为 false，move 成功后才为 true（区分 Finder 移动 vs 非 promise 交付）
    func testDidCompleteMoveFlag() throws {
        let (item, srcURL) = try makeItem(named: "moveflag.txt")
        let manager = FilePromiseDragManager(item: item) { _ in }
        XCTAssertFalse(manager.didCompleteMove, "初始应为 false")

        // 同卷成功移动 → didCompleteMove = true
        let dest = tempDir.appendingPathComponent("moveflag-dest.txt")
        let exp = expectation(description: "move")
        manager.moveAndNotify(to: dest) { _ in exp.fulfill() }
        wait(for: [exp], timeout: 5)
        XCTAssertTrue(manager.didCompleteMove, "move 成功后应为 true")
        XCTAssertFalse(FileManager.default.fileExists(atPath: srcURL.path), "同卷移动后源应消失")
    }

    private func makeItem(named name: String) throws -> (ShelfItem, URL) {
        let url = tempDir.appendingPathComponent(name)
        try Data("payload".utf8).write(to: url)
        guard let item = ShelfItem.make(from: url) else {
            throw XCTSkip("无法构造 ShelfItem")
        }
        return (item, url)
    }
}
