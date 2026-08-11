import Foundation
import CoreGraphics

/// 面板相对屏幕的锚点（V2-2 副屏唤醒）。
///
/// 位置模型：锚点 + 偏移，而非全局绝对坐标。
/// - 跨屏幕一致：同一锚点在所有屏幕的观感位置一致（如都贴右上角）；
/// - 跨分辨率一致：偏移以屏幕「可见帧」的百分比表示，而非固定 pt。
enum PanelAnchor: String, CaseIterable, Codable, Equatable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
}

/// 锚点偏移：以所在屏幕「可见帧」的百分比表示（跨分辨率一致）。
/// dx/dy 为向屏幕内侧的无符号比例（0...1），例如 `.topRight + (0.04, 0.10)`
/// = 面板角距可见帧右缘 4% 屏宽、距顶缘 10% 屏高。
struct PanelOffset: Codable, Equatable, Sendable {
    var dx: Double
    var dy: Double
}

/// 面板相对位置 = 锚点 + 偏移。
struct PanelPosition: Codable, Equatable, Sendable {
    var anchor: PanelAnchor
    var offset: PanelOffset
}

/// 面板定位纯几何逻辑（不依赖 NSScreen，矩形注入即可单元测试）。
enum PanelPositioning {
    /// 默认锚点：右上角（V1 默认位置语义，改用百分比偏移以跨分辨率一致）
    static let defaultPosition = PanelPosition(
        anchor: .topRight,
        offset: PanelOffset(dx: 0.04, dy: 0.10)
    )

    /// 目标屏幕索引：鼠标所在屏（用全 frame 命中，菜单栏/停靠栏区域也能命中）；
    /// 无鼠标 → fallbackIndex；鼠标不在任何屏（边界/间隙）→ 距离最近的屏。
    static func targetScreenIndex(
        mouseLocation: CGPoint?,
        screenFrames: [CGRect],
        fallbackIndex: Int
    ) -> Int {
        guard let mouse = mouseLocation, !screenFrames.isEmpty else { return fallbackIndex }
        if let hit = screenFrames.firstIndex(where: { $0.contains(mouse) }) {
            return hit
        }
        return screenFrames.enumerated()
            .min { distanceSquared(from: mouse, to: $0.element) < distanceSquared(from: mouse, to: $1.element) }?
            .offset ?? fallbackIndex
    }

    /// 锚点 + 偏移 → 面板 frame（在目标屏「可见帧」内）。
    static func frame(
        for panelSize: CGSize,
        in visibleFrame: CGRect,
        position: PanelPosition
    ) -> CGRect {
        let dx = visibleFrame.width * CGFloat(position.offset.dx)
        let dy = visibleFrame.height * CGFloat(position.offset.dy)
        let origin: CGPoint
        switch position.anchor {
        case .topLeft:
            origin = CGPoint(x: visibleFrame.minX + dx, y: visibleFrame.maxY - panelSize.height - dy)
        case .topRight:
            origin = CGPoint(x: visibleFrame.maxX - panelSize.width - dx, y: visibleFrame.maxY - panelSize.height - dy)
        case .bottomLeft:
            origin = CGPoint(x: visibleFrame.minX + dx, y: visibleFrame.minY + dy)
        case .bottomRight:
            origin = CGPoint(x: visibleFrame.maxX - panelSize.width - dx, y: visibleFrame.minY + dy)
        }
        return CGRect(origin: origin, size: panelSize)
    }

    /// 面板 frame 反算 → 锚点 + 偏移（拖动结束持久化用）。
    /// 取「归一化距离最近」的角作为锚点，偏移为向内侧的距离比例。
    static func position(for panelFrame: CGRect, in visibleFrame: CGRect) -> PanelPosition {
        let candidates: [(anchor: PanelAnchor, dx: CGFloat, dy: CGFloat)] = [
            (.topLeft, panelFrame.minX - visibleFrame.minX, visibleFrame.maxY - panelFrame.maxY),
            (.topRight, visibleFrame.maxX - panelFrame.maxX, visibleFrame.maxY - panelFrame.maxY),
            (.bottomLeft, panelFrame.minX - visibleFrame.minX, panelFrame.minY - visibleFrame.minY),
            (.bottomRight, visibleFrame.maxX - panelFrame.maxX, panelFrame.minY - visibleFrame.minY)
        ]
        let best = candidates.min { a, b in
            normalizedScore(dx: a.dx, dy: a.dy, in: visibleFrame)
                < normalizedScore(dx: b.dx, dy: b.dy, in: visibleFrame)
        }!
        return PanelPosition(
            anchor: best.anchor,
            offset: PanelOffset(
                dx: clampedFraction(best.dx / visibleFrame.width),
                dy: clampedFraction(best.dy / visibleFrame.height)
            )
        )
    }

    /// 初始/唤醒定位决策：
    /// 1. 新模型（锚点+偏移）存在 → 按目标屏相对锚点定位；
    /// 2. 否则 V1 旧绝对坐标仍落在某屏 → 用旧位置（V1 升级迁移，等待拖动反算）；
    /// 3. 否则默认锚点（右上角 + 默认百分比偏移）。
    static func resolvedFrame(
        panelSize: CGSize,
        targetVisibleFrame: CGRect,
        storedPosition: PanelPosition?,
        legacyFrame: CGRect?,
        screenFrames: [CGRect]
    ) -> CGRect {
        if let position = storedPosition {
            return frame(for: panelSize, in: targetVisibleFrame, position: position)
        }
        if let legacy = legacyFrame, screenFrames.contains(where: { $0.intersects(legacy) }) {
            return legacy
        }
        return frame(for: panelSize, in: targetVisibleFrame, position: defaultPosition)
    }

    // MARK: - 私有工具

    /// 点到矩形的最短距离平方（点在矩形内时为 0）。
    private static func distanceSquared(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    /// 以可见帧尺寸归一化后的角距离平方（分辨率无关，用于选择最近锚点）。
    private static func normalizedScore(dx: CGFloat, dy: CGFloat, in visibleFrame: CGRect) -> CGFloat {
        let nx = dx / visibleFrame.width
        let ny = dy / visibleFrame.height
        return nx * nx + ny * ny
    }

    private static func clampedFraction(_ value: CGFloat) -> Double {
        Double(min(max(value, 0), 1))
    }
}

/// 面板位置持久化（UserDefaults）：
/// 新模型 `panelAnchor` + `panelOffset`（百分比偏移，JSON 编码）；兼容读取 V1
/// `panelFrame` 绝对坐标作 fallback（V1 升级用户首次显示旧位置，拖动后迁移到新模型）。
final class PanelPositionStore {
    enum Keys {
        static let anchor = "panelAnchor"
        static let offset = "panelOffset"
        static let legacyFrame = "panelFrame"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 新模型位置；缺失/损坏返回 nil（触发 V1 fallback）。
    var position: PanelPosition? {
        guard let raw = defaults.string(forKey: Keys.anchor),
              let anchor = PanelAnchor(rawValue: raw),
              let data = defaults.data(forKey: Keys.offset),
              let offset = try? JSONDecoder().decode(PanelOffset.self, from: data) else {
            return nil
        }
        return PanelPosition(anchor: anchor, offset: offset)
    }

    /// V1 旧绝对坐标（仅 fallback 读取，不写回）。
    var legacyFrame: NSRect? {
        guard let data = defaults.data(forKey: Keys.legacyFrame),
              let rect = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSValue.self, from: data),
              rect.responds(to: #selector(getter: NSValue.rectValue)) else {
            return nil
        }
        return rect.rectValue
    }

    func save(_ position: PanelPosition) {
        defaults.set(position.anchor.rawValue, forKey: Keys.anchor)
        if let data = try? JSONEncoder().encode(position.offset) {
            defaults.set(data, forKey: Keys.offset)
        }
    }

    /// 拖动结束反算并保存：面板 frame → 相对所在屏的锚点+偏移（迁移到新模型）。
    func save(from panelFrame: NSRect, in visibleFrame: NSRect) {
        save(PanelPositioning.position(for: panelFrame, in: visibleFrame))
    }
}
