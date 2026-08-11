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
}
