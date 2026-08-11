import SwiftUI
import AppKit

@main
struct FileTmpShelfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
        }
    }
}

/// 应用委托：负责菜单栏常驻、全局热键注册、面板生命周期。
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var hotKeyManager: HotKeyManager?
    private var panelController: ShelfPanelController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // 菜单栏
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: "FileTmpShelf")
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "显示/隐藏货架 (⌥C)", action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(withTitle: "清空货架", action: #selector(clearShelf), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        item.menu = menu
        statusItem = item

        // 面板
        panelController = ShelfPanelController()
        panelController?.onItemCountChange = { [weak self] count in
            self?.updateBadge(count: count)
        }

        // 全局热键：单元测试宿主环境下跳过，避免与测试自身的注册冲突
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            let hotKey = HotKeyManager(keyCode: HotKeyManager.keyCodeForOptionC, modifiers: [.option])
            hotKey.onTrigger = { [weak self] in
                self?.togglePanel()
            }
            hotKeyManager = hotKey
            registerHotKey(hotKey)
        }
    }

    private func registerHotKey(_ hotKey: HotKeyManager) {
        do {
            try hotKey.register()
        } catch HotKeyManager.RegisterError.hotKeyExists {
            NSLog("⌥C 已被其他应用占用，快捷键不可用")
            statusItem?.menu?.item(at: 0)?.title = "显示/隐藏货架 (⌥C) — 快捷键冲突"
        } catch {
            NSLog("热键注册失败: %@", String(describing: error))
            statusItem?.menu?.item(at: 0)?.title = "显示/隐藏货架 (⌥C) — 注册失败"
        }
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
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

struct SettingsView: View {
    var body: some View {
        Text("设置（快捷键自定义等）将在 V1 开发中实现")
            .padding(24)
            .frame(width: 320, height: 160)
    }
}
