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
    /// 类级强引用（根治 objc_retain 悬垂崩溃）：
    /// SwiftUI `@NSApplicationDelegateAdaptor` 在 accessory app（无主窗口场景）
    /// 的某些生命周期路径下可能释放 AppDelegate；menu item target 指向本实例，
    /// 若被释放 → 点击菜单 objc_retain EXC_BAD_ACCESS。启动时把 self 存入
    /// static 持有，保证 AppDelegate 永不释放（与 adaptor 创建的是同一实例）。
    private static weak var liveReference: AppDelegate?
    private static var retained: AppDelegate?
    private var statusItem: NSStatusItem?
    private var hotKeyManager: HotKeyManager?
    private var panelController: ShelfPanelController?
    private var settingsWindow: NSWindow?
    private let settings = SettingsStore.shared
    private var settingsCancellable: AnyCancellable?
    private var lastHotKey: (keyCode: UInt32, modifiers: NSEvent.ModifierFlags)?
    private var lastPanelOpacity: Double = SettingsStore.shared.panelOpacity

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 根治悬垂崩溃：static 强持有 self（同一实例），保证菜单 target 永不失效
        Self.liveReference = self
        Self.retained = self

        NSApp.setActivationPolicy(.accessory)

        // 菜单栏
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: "FileTmpShelf")
        }
        let menu = NSMenu()
        // 显式设置 target = self：SwiftUI App 生命周期下 responder chain 路由
        // 到 NSApp.delegate（SwiftUI 适配器包装对象）可能悬垂，导致点击"设置…"崩溃
        // （EXC_BAD_ACCESS objc_retain in AppDelegate.openSettings）。
        func addItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            return item
        }
        menu.addItem(addItem(hotKeyMenuTitle(), #selector(togglePanel)))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(addItem("设置…", #selector(openSettings), key: ","))
        menu.addItem(addItem("退出", #selector(quit), key: "q"))
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

    /// 菜单栏角标：条目数 > 0 时显示数字（体验增强 3.4）
    func updateBadge(count: Int) {
        statusItem?.button?.title = count > 0 ? " \(count)" : ""
    }

    @objc private func openSettings() {
        // 修复：accessory 应用（无 Dock 图标）下 NSApp.sendAction("showSettingsWindow:")
        // 无法路由到 SwiftUI Settings 场景，设置窗口从未被创建。
        // 改为 AppDelegate 手动持有设置窗口（NSWindow + SettingsView），
        // 保持系统设置窗口观感（标题栏/可关闭），与 Settings 场景并存。
        
        // ⚠️ 关键修复：不覆盖/不重建已有窗口。
        // 当用户点击窗口关闭按钮时，NSWindow 不会立即释放（hasScaledBackingStore
        // 和动画缓冲），只是隐藏（isVisible = false）。如果此时我们创建新窗口并
        // 赋值 settingsWindow = newWindow，旧窗口的强引用被释放，触发
        // _NSWindowTransformAnimation dealloc 悬垂崩溃。
        // 正确做法：始终复用同一个窗口，只是 show/hide。
        
        if settingsWindow == nil {
            // 首次创建
            let content = NSHostingView(rootView: SettingsView())
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "FileTmpShelf 设置"
            window.contentView = content
            window.center()
            // ⚠️ 关键：设置 isReleasedWhenClosed = false
            // 这样关闭窗口时窗口不会立即释放，而是保持强引用在 AppDelegate 中
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        
        // 显示/置顶已有窗口
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.orderFront(nil)
        // accessory app 下 makeKeyAndOrderFront 可能不生效
        if !settingsWindow!.isVisible {
            settingsWindow?.orderFrontRegardless()
        }
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
    /// 使用全局共享实例（崩溃修复：@State 独立实例每次 init 创建新 actor，
    /// 与面板实例并发操作同一存储 → 悬垂崩溃；shared 由 actor 隔离串行化）
    @State private var shelfStore = ShelfStore.shared

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
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("面板透明度")
                        Spacer()
                        // 当前百分比显示（Bug 修复：原实现无百分比，且 Slider 内 accessibility
                        // label 的 Text("面板透明度") 被渲染为可见文本导致"出现二次"）
                        Text("\(Int(store.panelOpacity * 100))%")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $store.panelOpacity, in: 0.5...1.0) {
                        // 空 accessibility label：外部 HStack 已有可见标签，避免重复渲染
                        EmptyView()
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

            Section("危险操作") {
                Button(role: .destructive, action: clearAllShelves) {
                    Label("清除所有货架", systemImage: "trash")
                }
                .help("移除货架上的全部条目")
                Text("将清空全部货架上的条目（保留货架本身）。仅移除引用，不会删除任何源文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("关于 FileTmpShelf") {
                HStack(spacing: 12) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("FileTmpShelf")
                            .font(.headline)
                        Text("版本 \(AppInfo.version())")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("GitHub 仓库")
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(AppInfo.repoURL)
                    } label: {
                        Text(AppInfo.repoURL.absoluteString)
                    }
                    .buttonStyle(.link)
                    .help("在浏览器中打开 GitHub 仓库")
                }
                Text("基于 MIT 许可证开源发布，源码见 GitHub 仓库。")
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

    // MARK: - 清除所有货架（V2-3 / V2-4 多货架遍历）

    /// 清除所有货架：复用清空确认阈值逻辑（≤阈值直接清空，>阈值或「始终确认」弹确认），
    /// 确认后调用 ShelfStore.clearAllShelves()（多货架遍历清空全部货架的条目，保留货架本身）。
    /// 只移除引用，不删除源文件。
    private func clearAllShelves() {
        Task { @MainActor in
            await shelfStore.load()
            let count = await shelfStore.totalItemCount
            guard count > 0 else { return }

            if SettingsStore.needsConfirmation(itemCount: count, threshold: store.clearThreshold) {
                let alert = NSAlert()
                alert.messageText = "确定清除所有货架？"
                alert.informativeText = "将移除全部货架共 \(count) 个条目（仅移除引用，不会删除任何源文件）。"
                alert.addButton(withTitle: "清除")
                alert.addButton(withTitle: "取消")
                alert.alertStyle = .warning
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }

            await shelfStore.clearAllShelves()
            NotificationCenter.default.post(name: .shelfDidClearAll, object: nil)
        }
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
