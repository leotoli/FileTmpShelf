import SwiftUI
import AppKit
import Carbon.HIToolbox
import Combine

@main
struct FileTmpShelfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

/// 应用委托：负责菜单栏常驻、全局热键注册、面板生命周期、设置应用。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotKeyManager: HotKeyManager?
    private var panelController: ShelfPanelController?
    private var settingsWindow: NSWindow?
    private let settings = SettingsStore.shared
    private var settingsCancellable: AnyCancellable?
    private var lastHotKey: (keyCode: UInt32, modifiers: NSEvent.ModifierFlags)?
    private var lastPanelOpacity: Double = SettingsStore.shared.panelOpacity

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 菜单栏
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: "FileTmpShelf")
        }
        let menu = NSMenu()
        menu.addItem(withTitle: hotKeyMenuTitle(), action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(withTitle: "清空货架", action: #selector(clearShelf), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        item.menu = menu
        statusItem = item

        // 面板
        panelController = ShelfPanelController(settings: settings)
        panelController?.onItemCountChange = { [weak self] count in
            self?.updateBadge(count: count)
        }

        // 调试钩子：open --args -showPanelOnLaunch YES 启动即显示面板
        // （绕过全局热键，便于 GUI 自动化验收）
        if UserDefaults.standard.bool(forKey: "showPanelOnLaunch") {
            panelController?.show()
        }

        // 全局热键：单元测试宿主环境下跳过，避免与测试自身的注册冲突
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            let hotKey = HotKeyManager(keyCode: settings.hotKeyKeyCode, modifiers: settings.hotKeyModifiers)
            hotKey.onTrigger = { [weak self] in
                self?.togglePanel()
            }
            hotKeyManager = hotKey
            registerHotKey(hotKey)
        }

        // 监听设置变化：热键变化重注册、透明度应用到 NSPanel（Task 1/2）
        settingsCancellable = settings.objectWillChange.sink { [weak self] in
            self?.applySettings()
        }
    }

    private func registerHotKey(_ hotKey: HotKeyManager) {
        do {
            try hotKey.register()
            lastHotKey = (settings.hotKeyKeyCode, settings.hotKeyModifiers)
            updateHotKeyMenuTitle()
        } catch HotKeyManager.RegisterError.hotKeyExists {
            NSLog("快捷键已被其他应用占用，快捷键不可用")
            updateHotKeyMenuTitle(conflict: true)
        } catch {
            NSLog("热键注册失败: %@", String(describing: error))
            updateHotKeyMenuTitle(registrationFailed: true)
        }
    }

    /// 设置变化后的运行时应用：热键重注册 + 面板透明度
    private func applySettings() {
        let code = settings.hotKeyKeyCode
        let mods = settings.hotKeyModifiers
        if let hotKeyManager, let last = lastHotKey, (code, mods) != last {
            do {
                try hotKeyManager.update(keyCode: code, modifiers: mods)
                lastHotKey = (code, mods)
                updateHotKeyMenuTitle()
            } catch HotKeyManager.RegisterError.hotKeyExists {
                NSLog("新快捷键已被其他应用占用，快捷键不可用")
                updateHotKeyMenuTitle(conflict: true)
            } catch {
                NSLog("热键重注册失败: %@", String(describing: error))
                updateHotKeyMenuTitle(registrationFailed: true)
            }
        }

        let opacity = settings.panelOpacity
        if lastPanelOpacity != opacity {
            lastPanelOpacity = opacity
            panelController?.applyOpacity(opacity)
        }
    }

    private func hotKeyMenuTitle() -> String {
        "显示/隐藏货架 (\(HotKeyManager.displayString(keyCode: settings.hotKeyKeyCode, modifiers: settings.hotKeyModifiers)))"
    }

    private func updateHotKeyMenuTitle(conflict: Bool = false, registrationFailed: Bool = false) {
        var title = hotKeyMenuTitle()
        if conflict {
            title += " — 快捷键冲突"
        } else if registrationFailed {
            title += " — 注册失败"
        }
        statusItem?.menu?.item(at: 0)?.title = title
    }

    @objc private func togglePanel() {
        panelController?.toggle()
    }

    @objc private func clearShelf() {
        guard let panelController else { return }
        panelController.clearAllWithConfirmation()
    }

    /// 菜单栏角标：条目数 > 0 时显示数字（体验增强 3.4）
    func updateBadge(count: Int) {
        statusItem?.button?.title = count > 0 ? " \(count)" : ""
    }

    @objc private func openSettings() {
        // 修复：accessory 应用（无 Dock 图标）下 NSApp.sendAction("showSettingsWindow:")
        // 无法路由到 SwiftUI Settings 场景，设置窗口从未被创建。
        // 改为 AppDelegate 手动持有设置窗口（NSWindow + SettingsView），
        // 保持系统设置窗口观感（标题栏/可关闭），与 Settings 场景并存。
        if settingsWindow == nil {
            let content = NSHostingView(rootView: SettingsView())
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "FileTmpShelf 设置"
            window.contentView = content
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

/// 设置窗口（SwiftUI Settings 场景）：快捷键录制 / 开机启动 / 外观 / 清空策略。
struct SettingsView: View {
    @ObservedObject private var store = SettingsStore.shared
    @State private var isRecording = false
    @State private var recordingMonitor: Any?
    @State private var hotKeyError: String?
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("快捷键") {
                HStack {
                    Text("唤出货架")
                    Spacer()
                    if isRecording {
                        Text("按下新组合键…")
                            .foregroundStyle(.secondary)
                    } else {
                        Button(action: startRecording) {
                            Text(hotKeyLabel)
                                .monospaced()
                                .frame(minWidth: 110)
                        }
                        .help("点击后按下新的组合键")
                    }
                }
                Text("点击后直接按下组合键（需至少一个 ⌘ / ⌥ / ⌃ / ⇧ 修饰键）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let hotKeyError {
                    Text(hotKeyError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("通用") {
                Toggle("登录时自动启动", isOn: launchAtLoginBinding)
                if let launchAtLoginError {
                    Text(launchAtLoginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("外观") {
                HStack {
                    Text("面板透明度")
                    Slider(value: $store.panelOpacity, in: 0.5...1.0) {
                        Text("面板透明度")
                    } minimumValueLabel: {
                        Text("50%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } maximumValueLabel: {
                        Text("100%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("清空") {
                Picker("清空确认阈值", selection: $store.clearThreshold) {
                    Text("3 条以内直接清空").tag(3)
                    Text("5 条以内直接清空").tag(5)
                    Text("10 条以内直接清空").tag(10)
                    Text("始终确认").tag(SettingsStore.alwaysConfirmThreshold)
                }
                Text("超过阈值时清空货架前弹确认；「始终确认」则每次都确认。清空只移除引用，不删除源文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .onDisappear { stopRecording() }
    }

    private var hotKeyLabel: String {
        HotKeyManager.displayString(keyCode: store.hotKeyKeyCode, modifiers: store.hotKeyModifiers)
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { store.launchAtLogin },
            set: { newValue in
                store.launchAtLogin = newValue
                do {
                    try store.applyLaunchAtLogin(newValue)
                    launchAtLoginError = nil
                } catch {
                    // 未签名 app 注册失败：回滚开关并展示可读错误（正式 dmg 签名后自动生效）
                    store.launchAtLogin = !newValue
                    launchAtLoginError = "登录项注册失败：\(error.localizedDescription)（开发期未签名 app 常见，正式安装包将自动生效）"
                }
            }
        )
    }

    // MARK: - 快捷键录制

    private func startRecording() {
        hotKeyError = nil
        isRecording = true
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isRecording else { return event }
            return captureKeyDown(event)
        }
    }

    /// 录制一次按键：禁纯修饰键；需至少一个修饰键；成功后写入 store 并结束录制。
    private func captureKeyDown(_ event: NSEvent) -> NSEvent? {
        // 纯修饰键（仅按下 ⌘/⌥/⌃/⇧ 等本体）不构成组合键，忽略并继续等待
        let modifierKeyCodes: Set<CGKeyCode> = [
            CGKeyCode(kVK_Command), CGKeyCode(kVK_Shift), CGKeyCode(kVK_Option), CGKeyCode(kVK_Control),
            CGKeyCode(kVK_RightCommand), CGKeyCode(kVK_RightShift), CGKeyCode(kVK_RightOption), CGKeyCode(kVK_RightControl),
            CGKeyCode(kVK_CapsLock), CGKeyCode(kVK_Function)
        ]
        guard !modifierKeyCodes.contains(CGKeyCode(event.keyCode)) else {
            return nil
        }

        let modifiers = event.modifierFlags.intersection(SettingsStore.allowedModifiers)
        guard !modifiers.isEmpty else {
            hotKeyError = "全局快捷键需要至少一个修饰键（⌘ / ⌥ / ⌃ / ⇧），请重新按下"
            return nil
        }

        store.hotKeyKeyCode = UInt32(event.keyCode)
        store.hotKeyModifiers = modifiers
        hotKeyError = nil
        stopRecording()
        return nil
    }

    private func stopRecording() {
        if let recordingMonitor {
            NSEvent.removeMonitor(recordingMonitor)
        }
        recordingMonitor = nil
        isRecording = false
    }
}
