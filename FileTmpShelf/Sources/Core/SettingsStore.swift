import AppKit
import Combine
import ServiceManagement

/// 设置存储：UserDefaults 的 ObservableObject 封装（MVP Task 1/2）。
///
/// 覆盖：全局快捷键（键码 + 修饰符）、开机启动、面板透明度、清空确认阈值。
/// 值以原始类型持久化到 UserDefaults，读取/写入时统一校验，非法值回退默认。
/// 所有 setter 触发 `objectWillChange`，AppDelegate 监听后做运行时应用
/// （热键重注册、透明度应用到面板）。
final class SettingsStore: ObservableObject {
    enum Keys {
        static let hotKeyKeyCode = "settings.hotKey.keyCode"
        static let hotKeyModifiers = "settings.hotKey.modifiers"
        static let launchAtLogin = "settings.launchAtLogin"
        static let panelOpacity = "settings.panelOpacity"
        static let clearThreshold = "settings.clearThreshold"
    }

    /// 默认快捷键 ⌥C：C = kVK_ANSI_C = 8
    static let defaultKeyCode: UInt32 = 8
    static let defaultModifiers: NSEvent.ModifierFlags = [.option]
    static let defaultPanelOpacity: Double = 0.9
    static let defaultClearThreshold: Int = 3

    /// 清空确认阈值可选值；0 为「始终确认」哨兵
    static let clearThresholdOptions: [Int] = [3, 5, 10, 0]
    static let alwaysConfirmThreshold = 0

    /// 允许持久化/录制的修饰键位（Carbon 全局热键只认这四个）
    static let allowedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    /// App 级共享实例：AppDelegate 与 SettingsView 共用，保证 objectWillChange 通知互通
    static let shared = SettingsStore()

    private let defaults: UserDefaults

    @Published private var storedKeyCode: UInt32
    @Published private var storedModifiers: NSEvent.ModifierFlags
    @Published private var storedLaunchAtLogin: Bool
    @Published private var storedPanelOpacity: Double
    @Published private var storedClearThreshold: Int

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        storedKeyCode = Self.sanitizedKeyCode(defaults.object(forKey: Keys.hotKeyKeyCode) as? Int)
        storedModifiers = Self.sanitizedModifiers(defaults.object(forKey: Keys.hotKeyModifiers) as? UInt)
        storedLaunchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        storedPanelOpacity = Self.sanitizedOpacity(defaults.object(forKey: Keys.panelOpacity) as? Double)
        storedClearThreshold = Self.sanitizedThreshold(defaults.object(forKey: Keys.clearThreshold) as? Int)
    }

    // MARK: - 全局快捷键

    var hotKeyKeyCode: UInt32 {
        get { storedKeyCode }
        set {
            storedKeyCode = Self.sanitizedKeyCode(Int(newValue))
            defaults.set(Int(storedKeyCode), forKey: Keys.hotKeyKeyCode)
        }
    }

    var hotKeyModifiers: NSEvent.ModifierFlags {
        get { storedModifiers }
        set {
            storedModifiers = Self.sanitizedModifiers(newValue.rawValue)
            defaults.set(storedModifiers.rawValue, forKey: Keys.hotKeyModifiers)
        }
    }

    // MARK: - 开机启动

    var launchAtLogin: Bool {
        get { storedLaunchAtLogin }
        set {
            storedLaunchAtLogin = newValue
            defaults.set(newValue, forKey: Keys.launchAtLogin)
        }
    }

    /// 应用开机启动偏好到 SMAppService.mainApp。
    /// 未签名 app（开发期）register 会抛错，由 UI 层捕获展示并回滚开关；
    /// 偏好值本身独立于系统注册状态持久化。
    func applyLaunchAtLogin(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status != .notRegistered else { return }
            try service.unregister()
        }
    }

    // MARK: - 外观

    var panelOpacity: Double {
        get { storedPanelOpacity }
        set {
            storedPanelOpacity = Self.sanitizedOpacity(newValue)
            defaults.set(storedPanelOpacity, forKey: Keys.panelOpacity)
        }
    }

    // MARK: - 清空策略

    var clearThreshold: Int {
        get { storedClearThreshold }
        set {
            storedClearThreshold = Self.sanitizedThreshold(newValue)
            defaults.set(storedClearThreshold, forKey: Keys.clearThreshold)
        }
    }

    // MARK: - 校验（非法值回退默认）

    private static func sanitizedKeyCode(_ raw: Int?) -> UInt32 {
        guard let raw, (0..<128).contains(raw) else { return defaultKeyCode }
        return UInt32(raw)
    }

    private static func sanitizedModifiers(_ raw: UInt?) -> NSEvent.ModifierFlags {
        guard let raw else { return defaultModifiers }
        let mods = NSEvent.ModifierFlags(rawValue: raw).intersection(allowedModifiers)
        // 无任何修饰键位（纯按键）不构成合法全局快捷键，回退默认
        return mods.isEmpty ? defaultModifiers : mods
    }

    private static func sanitizedOpacity(_ raw: Double?) -> Double {
        guard let raw, (0.5...1.0).contains(raw) else { return defaultPanelOpacity }
        return raw
    }

    private static func sanitizedThreshold(_ raw: Int?) -> Int {
        guard let raw, clearThresholdOptions.contains(raw) else { return defaultClearThreshold }
        return raw
    }
}
