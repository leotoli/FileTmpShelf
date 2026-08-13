import XCTest
@testable import FileTmpShelf

/// MVP Task 1/2 — SettingsStore：默认值 / 读写 round-trip / 非法值回退默认。
/// 使用隔离的 UserDefaults suite，不触碰用户真实偏好。
final class SettingsStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "SettingsStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults?.removePersistentDomain(forName: suiteName)
    }

    // MARK: - 默认值

    /// 空 UserDefaults 下应全部回退默认：⌥X（keyCode 7 + .option）、透明度 0.9、阈值 3、不开机启动
    func testDefaults() {
        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(SettingsStore.defaultKeyCode, 7)
        XCTAssertEqual(store.hotKeyKeyCode, 7)
        XCTAssertEqual(store.hotKeyKeyCode, SettingsStore.defaultKeyCode)
        XCTAssertEqual(store.hotKeyModifiers, SettingsStore.defaultModifiers)
        XCTAssertEqual(store.hotKeyModifiers, [.option])
        XCTAssertEqual(store.panelOpacity, SettingsStore.defaultPanelOpacity, accuracy: 0.0001)
        XCTAssertEqual(store.clearThreshold, SettingsStore.defaultClearThreshold)
        XCTAssertFalse(store.launchAtLogin)
    }

    // MARK: - 读写 round-trip

    /// 写入全部设置项后，新实例应从 UserDefaults 读回相同值（重启保持语义）
    func testRoundTrip() {
        let store = SettingsStore(defaults: defaults)
        store.hotKeyKeyCode = 9
        store.hotKeyModifiers = [.command, .shift]
        store.panelOpacity = 0.65
        store.clearThreshold = 10
        store.launchAtLogin = true

        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.hotKeyKeyCode, 9)
        XCTAssertEqual(reloaded.hotKeyModifiers, [.command, .shift])
        XCTAssertEqual(reloaded.panelOpacity, 0.65, accuracy: 0.0001)
        XCTAssertEqual(reloaded.clearThreshold, 10)
        XCTAssertTrue(reloaded.launchAtLogin)
    }

    /// 启动自动启动开关 round-trip（纯偏好持久化，不触发 SMAppService）
    func testLaunchAtLoginRoundTrip() {
        let store = SettingsStore(defaults: defaults)
        store.launchAtLogin = true
        XCTAssertTrue(SettingsStore(defaults: defaults).launchAtLogin)

        store.launchAtLogin = false
        XCTAssertFalse(SettingsStore(defaults: defaults).launchAtLogin)
    }

    // MARK: - 非法值回退默认

    /// 写入的原始值非法（越界键码、空修饰符、超范围透明度、非法阈值、非布尔开机项）→ 全部回退默认
    func testInvalidValuesFallBackToDefaults() {
        defaults.set(-1, forKey: SettingsStore.Keys.hotKeyKeyCode)
        defaults.set(UInt(0), forKey: SettingsStore.Keys.hotKeyModifiers)
        defaults.set(2.0, forKey: SettingsStore.Keys.panelOpacity)
        defaults.set(7, forKey: SettingsStore.Keys.clearThreshold)
        defaults.set("yes", forKey: SettingsStore.Keys.launchAtLogin)

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.hotKeyKeyCode, SettingsStore.defaultKeyCode)
        XCTAssertEqual(store.hotKeyModifiers, SettingsStore.defaultModifiers)
        XCTAssertEqual(store.panelOpacity, SettingsStore.defaultPanelOpacity, accuracy: 0.0001)
        XCTAssertEqual(store.clearThreshold, SettingsStore.defaultClearThreshold)
        XCTAssertFalse(store.launchAtLogin)
    }

    /// 过大的键码（≥128）与低于下限的透明度也应回退默认
    func testOutOfRangeValuesFallBackToDefaults() {
        defaults.set(999, forKey: SettingsStore.Keys.hotKeyKeyCode)
        defaults.set(0.3, forKey: SettingsStore.Keys.panelOpacity)

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.hotKeyKeyCode, SettingsStore.defaultKeyCode)
        XCTAssertEqual(store.panelOpacity, SettingsStore.defaultPanelOpacity, accuracy: 0.0001)
    }

    /// 仅含非允许位（如 capsLock）的修饰符 → 净化后为空 → 回退默认
    func testNonAllowedModifierBitsFallBackToDefault() {
        defaults.set(UInt(NSEvent.ModifierFlags.capsLock.rawValue), forKey: SettingsStore.Keys.hotKeyModifiers)

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.hotKeyModifiers, SettingsStore.defaultModifiers)
    }

    // MARK: - setter 净化

    /// setter 直接写入非法值时也应即时回退默认并持久化净化后的值
    func testSettersSanitizeIllegalValues() {
        let store = SettingsStore(defaults: defaults)

        store.hotKeyKeyCode = 999
        XCTAssertEqual(store.hotKeyKeyCode, SettingsStore.defaultKeyCode)

        store.panelOpacity = 0.2
        XCTAssertEqual(store.panelOpacity, SettingsStore.defaultPanelOpacity, accuracy: 0.0001)

        store.clearThreshold = 4
        XCTAssertEqual(store.clearThreshold, SettingsStore.defaultClearThreshold)

        // 持久化的也是净化后的默认值
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.hotKeyKeyCode, SettingsStore.defaultKeyCode)
        XCTAssertEqual(reloaded.panelOpacity, SettingsStore.defaultPanelOpacity, accuracy: 0.0001)
        XCTAssertEqual(reloaded.clearThreshold, SettingsStore.defaultClearThreshold)
    }

    // MARK: - 清除确认策略（V2-3）

    /// ≤ 阈值直接清空；> 阈值或「始终确认」需弹确认（与面板清空共用同一策略）
    func testClearConfirmationPolicy() {
        XCTAssertFalse(SettingsStore.needsConfirmation(itemCount: 3, threshold: 3), "恰好等于阈值应直接清空")
        XCTAssertFalse(SettingsStore.needsConfirmation(itemCount: 1, threshold: 3), "小于阈值应直接清空")
        XCTAssertTrue(SettingsStore.needsConfirmation(itemCount: 4, threshold: 3), "大于阈值应确认")
        XCTAssertTrue(
            SettingsStore.needsConfirmation(itemCount: 5, threshold: SettingsStore.alwaysConfirmThreshold),
            "始终确认（阈值 0）时任何数量都应确认"
        )
        XCTAssertTrue(
            SettingsStore.needsConfirmation(itemCount: 0, threshold: SettingsStore.alwaysConfirmThreshold),
            "始终确认（阈值 0）时 0 条也按确认策略处理（调用方已 guard count > 0）"
        )
    }

    // MARK: - 关于信息（V2-3）

    /// 版本号读取：测试宿主下 Bundle.main 是测试 runner 的 Info.plist，读不到 app 版本，
    /// 故验证可注入的纯函数版本（AppInfo.version(from:) 默认读 Bundle.main）。
    func testAppInfoVersion() {
        XCTAssertEqual(AppInfo.version(from: ["CFBundleShortVersionString": "0.1.0"]), "0.1.0")
        XCTAssertEqual(AppInfo.version(from: ["CFBundleShortVersionString": "2.0.3"]), "2.0.3")
        XCTAssertEqual(AppInfo.version(from: [:]), "0.1.1", "缺失版本号应回退默认")
        XCTAssertEqual(AppInfo.version(from: ["CFBundleShortVersionString": ""]), "0.1.1", "空版本号应回退默认")
    }

    func testAppInfoRepoURL() {
        XCTAssertEqual(AppInfo.repoURL.absoluteString, "https://github.com/leotoli/FileTmpShelf")
    }
}
