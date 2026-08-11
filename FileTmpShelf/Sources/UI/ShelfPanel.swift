import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 浮动面板控制器：NSPanel 无边框、置顶、不抢焦点。
/// Spike S4 目标：验证面板作为拖入目标 + 拖出源的双向拖放行为。
final class ShelfPanelController: NSObject {
    private var panel: NSPanel?
    private let store = ShelfStore()

    /// 条目数变化回调（菜单栏角标用，体验增强 3.4）
    var onItemCountChange: ((Int) -> Void)?

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if panel == nil {
            createPanel()
        }
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// 清空货架（体验缺陷 2.2）：>3 条时确认；≤3 条直接清空。
    /// 只移除引用，不删除源文件。
    func clearAllWithConfirmation() {
        Task { @MainActor in
            let count = await store.count
            guard count > 0 else { return }

            if count > 3 {
                let alert = NSAlert()
                alert.messageText = "确定清空货架？"
                alert.informativeText = "将移除 \(count) 个货架条目（仅移除引用，不会删除任何源文件）。"
                alert.addButton(withTitle: "清空")
                alert.addButton(withTitle: "取消")
                alert.alertStyle = .warning
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }

            await store.removeAll()
            onItemCountChange?(0)
        }
    }

    private func createPanel() {
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 140),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.level = .floating
        newPanel.isFloatingPanel = true
        newPanel.becomesKeyOnlyIfNeeded = true
        newPanel.isMovableByWindowBackground = true
        newPanel.hidesOnDeactivate = false
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSHostingView(
            rootView: ShelfPanelView(store: store) { [weak self] count in
                self?.onItemCountChange?(count)
            }
        )
        newPanel.contentView = content

        // 位置记忆（体验增强 3.3）：优先恢复上次位置；仅当存储的屏幕已不存在
        // （显示器拔出/分辨率变化）时回退到主屏右上角。
        if let saved = ShelfPanelController.savedFrame {
            let onScreen = NSScreen.screens.contains { $0.frame.intersects(saved) }
            if onScreen {
                newPanel.setFrame(saved, display: false)
            } else {
                placeAtDefault(newPanel)
            }
        } else {
            placeAtDefault(newPanel)
        }

        // 监听面板移动，持久化位置
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: newPanel,
            queue: .main
        ) { [weak newPanel] _ in
            guard let newPanel else { return }
            ShelfPanelController.savedFrame = newPanel.frame
        }

        panel = newPanel
    }

    private func placeAtDefault(_ panel: NSPanel) {
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 540, y: frame.maxY - 180))
        }
    }

    /// 持久化的面板位置（UserDefaults）
    private static var savedFrame: NSRect? {
        get {
            guard let data = UserDefaults.standard.data(forKey: "panelFrame"),
                  let rect = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSValue.self, from: data),
                  rect.responds(to: #selector(getter: NSValue.rectValue)) else {
                return nil
            }
            return rect.rectValue
        }
        set {
            guard let newValue else {
                UserDefaults.standard.removeObject(forKey: "panelFrame")
                return
            }
            let value = NSValue(rect: newValue)
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: value, requiringSecureCoding: false) {
                UserDefaults.standard.set(data, forKey: "panelFrame")
            }
        }
    }
}

/// 面板 SwiftUI 内容
struct ShelfPanelView: View {
    @StateObject private var model: ShelfPanelModel

    init(store: ShelfStore, onItemsChange: ((Int) -> Void)? = nil) {
        _model = StateObject(wrappedValue: ShelfPanelModel(store: store))
        _model.wrappedValue.onItemsChange = onItemsChange
    }

    var body: some View {
        VStack(spacing: 8) {
            // 头部工具栏：条目数 + 清理失效 + 清空（体验缺陷 2.2 / 增强 3.2）
            HStack {
                Text("\(model.items.count) 个文件")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if model.hasUnreachable {
                    Button {
                        model.clearUnreachable()
                    } label: {
                        Image(systemName: "broom")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("清理失效条目")
                }
                if !model.items.isEmpty {
                    Button {
                        model.clearAll()
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("清空货架（仅移除引用，不删除源文件）")
                }
            }
            .padding(.horizontal, 4)
            .padding(.top, 2)

            if model.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .foregroundStyle(.secondary)
                    Text("拖文件到这里，或按 ⌥C 呼出")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(model.items) { item in
                            ShelfItemView(item: item) { moved in
                                model.removeItem(moved)
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(width: 520, height: 160)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            model.addDroppedFiles(providers)
            return true
        }
    }
}

/// 面板视图模型
final class ShelfPanelModel: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    private let store: ShelfStore
    /// 条目数变化回调（菜单栏角标，体验增强 3.4）
    var onItemsChange: ((Int) -> Void)?

    init(store: ShelfStore) {
        self.store = store
        Task { await load() }
    }

    private func notifyCount() {
        onItemsChange?(items.count)
    }

    private func load() async {
        await store.load()
        items = await store.all()
        notifyCount()
    }

    func addDroppedFiles(_ providers: [NSItemProvider]) {
        Task {
            var urls: [URL] = []
            for provider in providers {
                if let url = await loadFileURL(from: provider) {
                    urls.append(url)
                }
            }
            guard !urls.isEmpty else { return }
            let outcome = await store.addBatch(urls)
            items = await store.all()
            notifyCount()
            print("[ShelfPanel] 挂载 \(urls.count) 个文件, 共 \(outcome.count) 条, 耗时 \(String(format: "%.3f", outcome.elapsed))s")
        }
    }

    func removeItem(_ item: ShelfItem) {
        Task {
            await store.remove(id: item.id)
            items = await store.all()
            notifyCount()
        }
    }

    /// 是否存在失效条目（源文件已不可达）——决定是否显示"清理失效"按钮
    var hasUnreachable: Bool {
        items.contains { !$0.isReachable }
    }

    /// 清空货架（体验缺陷 2.2）：移除全部引用，不删除源文件
    func clearAll() {
        Task {
            await store.removeAll()
            items = await store.all()
            notifyCount()
        }
    }

    /// 清理失效条目（体验增强 3.2）：只移除不可达引用，无数据风险
    func clearUnreachable() {
        Task {
            await store.removeUnreachable()
            items = await store.all()
            notifyCount()
        }
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                let url: URL?
                if let data = item as? Data,
                   let parsed = URL(dataRepresentation: data, relativeTo: nil) {
                    url = parsed
                } else if let parsed = item as? URL {
                    url = parsed
                } else {
                    url = nil
                }
                continuation.resume(returning: url)
            }
        }
    }
}

/// 条目视图：图标 + 名称 + 大小 + 来源路径
/// 拖出（Spike S2）：不再用 `NSItemProvider(file URL)` 的复制语义。
/// SwiftUI `.onDrag` 无法承载 NSFilePromiseProvider（Apple 确认），故 overlay 一个
/// AppKit `FilePromiseDragView` 发起 promise 拖拽会话；Finder 兑现承诺时由
/// `FilePromiseDragManager` 执行真实 moveItem，实现"拖出 = 移动 + 货架移除"。
struct ShelfItemView: View {
    let item: ShelfItem
    /// 移动成功后的回调（通知货架移除该条目）
    var onMoveCompleted: (ShelfItem) -> Void

    @ViewBuilder
    var body: some View {
        if item.isReachable {
            content.overlay(
                FilePromiseDragRepresentable(item: item, onMoveCompleted: onMoveCompleted)
            )
        } else {
            content.opacity(0.6)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: item.isCloudPlaceholder ? "cloud" : "doc")
                    .font(.system(size: 20))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(item.sourceParentPath)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if !item.isReachable {
                    Text("不可达")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(8)
        .frame(width: 150, height: 56)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
