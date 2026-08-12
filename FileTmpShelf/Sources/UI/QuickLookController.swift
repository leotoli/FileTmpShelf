import AppKit
import Quartz
import Carbon.HIToolbox

/// 空格预览（V2-7）的可预览条目集 + 焦点条目。
/// 面板模型在每次选中/取消/移除后推送当前状态，空格触发时按它打开 QLPreviewPanel。
struct PreviewSelection {
    var items: [ShelfItem] = []
    var focusedID: UUID?
}

/// Quick Look 预览纯逻辑（可单测）：初始预览位置 + 方向键切换索引。
/// 不依赖 QLPreviewPanel，隔离"面板依赖真实预览"的部分。
enum QuickLookPreviewLogic {
    /// 计算初始预览位置：焦点条目在 `urls` 中的下标；焦点为空或不在集合中回退 0；
    /// 空集合返回 nil（无物可预览）。
    static func initialIndex(urls: [URL], focused: URL?) -> Int? {
        guard !urls.isEmpty else { return nil }
        guard let focused else { return 0 }
        return urls.firstIndex(of: focused) ?? 0
    }

    /// 方向键切换：在 `current` 基础上沿 `direction`（-1 / +1）移动，越界钳制
    /// （与 Finder Quick Look 一致，不环绕）；空集合返回 nil。
    static func nextIndex(current: Int, count: Int, direction: Int) -> Int? {
        guard count > 0 else { return nil }
        let target = current + direction
        return min(max(target, 0), count - 1)
    }
}

/// QLPreviewPanel 单例的 dataSource + delegate（V2-7）。
///
/// 生命周期约定：
/// - `toggle(selection:)`：面板已展示我们的预览 → 关闭（再按空格）；否则用当前选中集打开
/// - `close()`：面板隐藏 / 选中集清空时调用，把预览一并关掉（面板关闭 → 预览关闭）
/// - `previewPanelDidClose`：用户按 Esc 或点关闭按钮关掉面板后重置内部状态
///
/// 注：QLPreviewPanel 是系统单例面板，必须用真实面板才能出现预览；本类不注入
/// 协议抽象，单测只覆盖 QuickLookPreviewLogic 纯逻辑（见取舍说明）。
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// 当前预览文件（按货架顺序）
    private(set) var previewURLs: [URL] = []
    /// 当前预览项下标（方向键切换时更新）
    private(set) var currentIndex: Int = 0

    /// 当前预览项 URL
    var currentURL: URL? {
        guard previewURLs.indices.contains(currentIndex) else { return nil }
        return previewURLs[currentIndex]
    }

    /// 面板是否在展示「我们」的预览（避免关掉别处打开的系统 Quick Look）
    var isShowingOurs: Bool {
        guard let panel = QLPreviewPanel.shared(), panel.isVisible else { return false }
        return panel.dataSource === self
    }

    /// 空格切换：已打开（我们的）→ 关闭；否则以 `selection` 打开（多选集从焦点条目开始）。
    func toggle(selection: PreviewSelection) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if isShowingOurs {
            close()
            return
        }
        // 只预览可达文件（占位/失效条目无内容可看）
        let urls = selection.items.filter(\.isReachable).map(\.fileURL)
        let focused = selection.items.first { $0.id == selection.focusedID }?.fileURL
        guard let initial = QuickLookPreviewLogic.initialIndex(urls: urls, focused: focused) else {
            return
        }
        previewURLs = urls
        currentIndex = initial
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = initial
        panel.makeKeyAndOrderFront(nil)
    }

    /// 关闭预览（面板隐藏 / 选中清空时调用；只关我们自己的预览）
    func close() {
        guard let panel = QLPreviewPanel.shared() else {
            previewURLs = []
            return
        }
        if panel.dataSource === self, panel.isVisible {
            panel.orderOut(nil)
        }
        previewURLs = []
        currentIndex = 0
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel) -> Int {
        previewURLs.count
    }

    func previewPanel(_ panel: QLPreviewPanel, previewItemAt index: Int) -> QLPreviewItem {
        previewURLs[index] as NSURL
    }

    // MARK: - QLPreviewPanelDelegate

    /// 方向键切换（Finder 语义：← / → 上一个 / 下一个）。返回 true 表示已处理，
    /// 面板不再自行处理该事件（避免与原生导航双重响应）。
    func previewPanel(_ panel: QLPreviewPanel, handle event: NSEvent) -> Bool {
        let direction: Int
        switch event.keyCode {
        case UInt16(kVK_LeftArrow): direction = -1
        case UInt16(kVK_RightArrow): direction = 1
        default: return false
        }
        guard let next = QuickLookPreviewLogic.nextIndex(
            current: currentIndex,
            count: previewURLs.count,
            direction: direction
        ) else { return false }
        currentIndex = next
        panel.currentPreviewItemIndex = next
        return true
    }

    func previewPanelDidClose(_ panel: QLPreviewPanel) {
        previewURLs = []
        currentIndex = 0
    }
}
