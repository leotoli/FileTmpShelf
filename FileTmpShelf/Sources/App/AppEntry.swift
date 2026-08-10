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
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        item.menu = menu
        statusItem = item

        // 全局热键
        let hotKey = HotKeyManager(keyCode: HotKeyManager.keyCodeForOptionC, modifiers: [.option])
        hotKey.onTrigger = { [weak self] in
            self?.togglePanel()
        }
        hotKeyManager = hotKey

        // 面板
        panelController = ShelfPanelController()

        hotKey.register()
    }

    @objc private func togglePanel() {
        panelController?.toggle()
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
