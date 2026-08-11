import XCTest
@testable import FileTmpShelf

/// V2-2 副屏唤醒：面板位置模型从「全局绝对坐标」升级为「屏幕相对锚点+偏移」。
///
/// NSScreen 无法在单元测试中构造，故全部断言走纯逻辑（`PanelPositioning`，
/// 屏幕矩形注入）+ `PanelPositionStore` 持久化 round-trip。
/// 覆盖验收四场景：屏 A / 屏 B / 无鼠标与边界兜底 / V1 数据迁移。
final class ShelfPanelPositionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    // 屏幕几何（macOS 坐标：原点左下）：主屏 1920×1080，副屏 1280×800 位于其右侧
    private let mainFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let secondaryFrame = CGRect(x: 1920, y: 0, width: 1280, height: 800)
    private let mainVisible = CGRect(x: 0, y: 0, width: 1920, height: 1040)
    private let secondaryVisible = CGRect(x: 1920, y: 0, width: 1280, height: 720)
    private let panelSize = CGSize(width: 520, height: 140)

    override func setUpWithError() throws {
        suiteName = "ShelfPanelPositionTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: suiteName)
    }

    // MARK: - 目标屏幕选择

    /// 鼠标在屏 A 内 → 目标屏 = A
    func testMouseOnScreenAPlacesPanelOnScreenA() {
        let index = PanelPositioning.targetScreenIndex(
            mouseLocation: CGPoint(x: 500, y: 500),
            screenFrames: [mainFrame, secondaryFrame],
            fallbackIndex: 0
        )
        XCTAssertEqual(index, 0)

        let position = PanelPosition(anchor: .topRight, offset: PanelOffset(dx: 0.04, dy: 0.10))
        let frame = PanelPositioning.frame(for: panelSize, in: mainVisible, position: position)
        XCTAssertTrue(mainVisible.contains(frame.origin))
        XCTAssertEqual(frame.maxX, mainVisible.maxX - mainVisible.width * 0.04, accuracy: 0.001)
        XCTAssertEqual(frame.minX, mainVisible.maxX - panelSize.width - mainVisible.width * 0.04, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, mainVisible.maxY - mainVisible.height * 0.10, accuracy: 0.001)
    }

    /// 鼠标在屏 B 内 → 目标屏 = B，相对位置（右缘/顶缘比例）与屏 A 一致
    func testMouseOnScreenBPlacesPanelOnScreenB() {
        let index = PanelPositioning.targetScreenIndex(
            mouseLocation: CGPoint(x: 2200, y: 400),
            screenFrames: [mainFrame, secondaryFrame],
            fallbackIndex: 0
        )
        XCTAssertEqual(index, 1)

        let position = PanelPosition(anchor: .topRight, offset: PanelOffset(dx: 0.04, dy: 0.10))
        let frame = PanelPositioning.frame(for: panelSize, in: secondaryVisible, position: position)
        XCTAssertTrue(secondaryVisible.contains(frame.origin))
        XCTAssertEqual(frame.maxX, secondaryVisible.maxX - secondaryVisible.width * 0.04, accuracy: 0.001)
        XCTAssertEqual(frame.maxY, secondaryVisible.maxY - secondaryVisible.height * 0.10, accuracy: 0.001)

        // 「位置一致」= 相对比例一致（跨分辨率也一致）
        let onMain = PanelPositioning.frame(for: panelSize, in: mainVisible, position: position)
        XCTAssertEqual(
            (mainVisible.maxX - onMain.maxX) / mainVisible.width,
            (secondaryVisible.maxX - frame.maxX) / secondaryVisible.width,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            (mainVisible.maxY - onMain.maxY) / mainVisible.height,
            (secondaryVisible.maxY - frame.maxY) / secondaryVisible.height,
            accuracy: 0.0001
        )
    }

    /// 无鼠标位置 → 主屏兜底
    func testNoMouseFallsBackToMainScreen() {
        let index = PanelPositioning.targetScreenIndex(
            mouseLocation: nil,
            screenFrames: [mainFrame, secondaryFrame],
            fallbackIndex: 0
        )
        XCTAssertEqual(index, 0)
    }

    /// 鼠标在所有屏之外（边界/间隙）→ 取距离最近的屏
    func testMouseOffAllScreensPicksNearestScreen() {
        let index = PanelPositioning.targetScreenIndex(
            mouseLocation: CGPoint(x: -100, y: 500),
            screenFrames: [mainFrame, secondaryFrame],
            fallbackIndex: 0
        )
        XCTAssertEqual(index, 0)
    }

    /// 命中判定用全 frame 而非可见帧：鼠标在菜单栏区域（可见帧上方）仍应命中该屏
    func testMouseAboveVisibleFrameStillTargetsThatScreen() {
        let index = PanelPositioning.targetScreenIndex(
            mouseLocation: CGPoint(x: 2200, y: 750),
            screenFrames: [mainFrame, secondaryFrame],
            fallbackIndex: 0
        )
        XCTAssertEqual(index, 1)
    }

    // MARK: - 位置决策（V1 迁移）

    /// V1 数据迁移：有旧 panelFrame、无新锚点 → 用旧绝对位置
    func testV1LegacyFrameUsedWhenNoAnchorModel() {
        let legacy = CGRect(x: 100, y: 200, width: 520, height: 140)
        let frame = PanelPositioning.resolvedFrame(
            panelSize: panelSize,
            targetVisibleFrame: mainVisible,
            storedPosition: nil,
            legacyFrame: legacy,
            screenFrames: [mainFrame, secondaryFrame]
        )
        XCTAssertEqual(frame, legacy)
    }

    /// 旧 panelFrame 已不在任何屏（显示器拔出/分辨率变化）→ 回退默认锚点，而非用失效坐标
    func testLegacyFrameOffScreenFallsBackToDefaultAnchor() {
        let legacy = CGRect(x: 5000, y: 5000, width: 520, height: 140)
        let frame = PanelPositioning.resolvedFrame(
            panelSize: panelSize,
            targetVisibleFrame: mainVisible,
            storedPosition: nil,
            legacyFrame: legacy,
            screenFrames: [mainFrame, secondaryFrame]
        )
        XCTAssertEqual(
            frame,
            PanelPositioning.frame(for: panelSize, in: mainVisible, position: PanelPositioning.defaultPosition)
        )
    }

    /// 新模型（锚点+偏移）存在时优先于旧 panelFrame
    func testAnchorModelTakesPrecedenceOverLegacy() {
        let position = PanelPosition(anchor: .bottomLeft, offset: PanelOffset(dx: 0.05, dy: 0.05))
        let frame = PanelPositioning.resolvedFrame(
            panelSize: panelSize,
            targetVisibleFrame: mainVisible,
            storedPosition: position,
            legacyFrame: CGRect(x: 10, y: 10, width: 520, height: 140),
            screenFrames: [mainFrame, secondaryFrame]
        )
        XCTAssertEqual(frame, PanelPositioning.frame(for: panelSize, in: mainVisible, position: position))
    }

    // MARK: - 反算 round-trip（拖动结束持久化语义）

    /// 面板 frame → 反算锚点+偏移 → 再生成 frame 应一致
    func testPositionInverseRoundTrip() {
        let position = PanelPosition(anchor: .topRight, offset: PanelOffset(dx: 0.05, dy: 0.12))
        let frame = PanelPositioning.frame(for: panelSize, in: mainVisible, position: position)
        let back = PanelPositioning.position(for: frame, in: mainVisible)
        XCTAssertEqual(back.anchor, .topRight)
        XCTAssertEqual(back.offset.dx, 0.05, accuracy: 0.0001)
        XCTAssertEqual(back.offset.dy, 0.12, accuracy: 0.0001)
    }

    func testPositionInverseRoundTripBottomLeft() {
        let position = PanelPosition(anchor: .bottomLeft, offset: PanelOffset(dx: 0.08, dy: 0.06))
        let frame = PanelPositioning.frame(for: panelSize, in: mainVisible, position: position)
        let back = PanelPositioning.position(for: frame, in: mainVisible)
        XCTAssertEqual(back.anchor, .bottomLeft)
        XCTAssertEqual(back.offset.dx, 0.08, accuracy: 0.0001)
        XCTAssertEqual(back.offset.dy, 0.06, accuracy: 0.0001)
    }

    /// 拖动后持久化 → 新实例读回同值（跨启动保持相对位置）
    func testDragPersistThenReload() {
        let store = PanelPositionStore(defaults: defaults)
        let frame = PanelPositioning.frame(
            for: panelSize,
            in: mainVisible,
            position: PanelPosition(anchor: .topRight, offset: PanelOffset(dx: 0.05, dy: 0.12))
        )
        store.save(from: frame, in: mainVisible)

        let reloaded = PanelPositionStore(defaults: defaults)
        XCTAssertEqual(reloaded.position?.anchor, .topRight)
        XCTAssertEqual(reloaded.position?.offset.dx ?? 0, 0.05, accuracy: 0.0001)
        XCTAssertEqual(reloaded.position?.offset.dy ?? 0, 0.12, accuracy: 0.0001)
    }

    // MARK: - 持久化（新模型 + V1 fallback）

    /// 新 key 持久化 round-trip
    func testPositionStoreRoundTrip() {
        let store = PanelPositionStore(defaults: defaults)
        XCTAssertNil(store.position, "空存储不应有锚点模型")
        store.save(PanelPosition(anchor: .bottomRight, offset: PanelOffset(dx: 0.1, dy: 0.2)))

        let reloaded = PanelPositionStore(defaults: defaults)
        XCTAssertEqual(reloaded.position?.anchor, .bottomRight)
        XCTAssertEqual(reloaded.position?.offset.dx ?? 0, 0.1, accuracy: 0.0001)
        XCTAssertEqual(reloaded.position?.offset.dy ?? 0, 0.2, accuracy: 0.0001)
    }

    /// V1 `panelFrame`（NSKeyedArchiver NSValue）兼容读取，且此时锚点模型为 nil
    func testLegacyFrameReadCompatible() throws {
        let value = NSValue(rect: CGRect(x: 100, y: 100, width: 520, height: 140))
        let data = try NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: false)
        defaults.set(data, forKey: PanelPositionStore.Keys.legacyFrame)

        let store = PanelPositionStore(defaults: defaults)
        XCTAssertEqual(store.legacyFrame, CGRect(x: 100, y: 100, width: 520, height: 140))
        XCTAssertNil(store.position, "只有 V1 数据时锚点模型应为 nil")
    }

    // MARK: - 跨分辨率一致性

    /// 不同分辨率屏幕 + 同一锚点偏移 → 距边缘的相对比例完全一致
    func testAnchorConsistentAcrossResolutions() {
        let big = CGRect(x: 0, y: 0, width: 3840, height: 2000)
        let small = CGRect(x: 3840, y: 0, width: 1280, height: 720)
        let position = PanelPosition(anchor: .topRight, offset: PanelOffset(dx: 0.04, dy: 0.10))

        let onBig = PanelPositioning.frame(for: panelSize, in: big, position: position)
        let onSmall = PanelPositioning.frame(for: panelSize, in: small, position: position)

        XCTAssertEqual((big.maxX - onBig.maxX) / big.width, 0.04, accuracy: 0.0001)
        XCTAssertEqual((big.maxY - onBig.maxY) / big.height, 0.10, accuracy: 0.0001)
        XCTAssertEqual((small.maxX - onSmall.maxX) / small.width, 0.04, accuracy: 0.0001)
        XCTAssertEqual((small.maxY - onSmall.maxY) / small.height, 0.10, accuracy: 0.0001)
    }
}
