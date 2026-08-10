import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 浮动面板控制器：NSPanel 无边框、置顶、不抢焦点。
/// Spike S4 目标：验证面板作为拖入目标 + 拖出源的双向拖放行为。
final class ShelfPanelController: NSObject {
    private var panel: NSPanel?
    private let store = ShelfStore()

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

    private func createPanel() {
        let newPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 140),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        newPanel.level = .floating
        newPanel.isFloatingPanel = true
        newPanel.hidesOnDeactivate = false
        newPanel.backgroundColor = .clear
        newPanel.isOpaque = false
        newPanel.hasShadow = true
        newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSHostingView(
            rootView: ShelfPanelView(store: store)
        )
        newPanel.contentView = content

        // 记住上次位置；首次出现放在主屏右上角附近
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            newPanel.setFrameOrigin(NSPoint(x: frame.maxX - 540, y: frame.maxY - 180))
        }
        panel = newPanel
    }
}

/// 面板 SwiftUI 内容
struct ShelfPanelView: View {
    @StateObject private var model: ShelfPanelModel

    init(store: ShelfStore) {
        _model = StateObject(wrappedValue: ShelfPanelModel(store: store))
    }

    var body: some View {
        VStack(spacing: 8) {
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
                            ShelfItemView(item: item)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .frame(width: 520, height: 140)
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

    init(store: ShelfStore) {
        self.store = store
        Task { await load() }
    }

    private func load() async {
        await store.load()
        items = await store.all()
    }

    func addDroppedFiles(_ providers: [NSItemProvider]) {
        let urls = providers.compactMap { provider -> URL? in
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
            var result: URL?
            let semaphore = DispatchSemaphore(value: 0)
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    result = url
                } else if let url = item as? URL {
                    result = url
                }
                semaphore.signal()
            }
            semaphore.wait()
            return result
        }
        Task {
            let outcome = await store.addBatch(urls)
            items = await store.all()
            print("[ShelfPanel] 挂载 \(urls.count) 个文件, 共 \(outcome.count) 条, 耗时 \(String(format: "%.3f", outcome.elapsed))s")
        }
    }
}

/// 条目视图：图标 + 名称 + 大小 + 来源路径
struct ShelfItemView: View {
    let item: ShelfItem

    var body: some View {
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
