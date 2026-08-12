import Foundation

/// ⌘ 点击 / Shift 区间 / 普通点击的修饰符分类（UI 层把 NSEvent.modifierFlags 翻译为它）
enum SelectionModifier {
    case plain
    case command
    case shift
}

/// 多选状态（纯逻辑，可单测，V2-6）：⌘ 切换、Shift 区间、点击替换、清空、批量移除后同步。
/// `anchor` 记录 Shift 区间的锚点条目 id（最后一次 ⌘/普通点击的条目）。
struct ShelfSelection {
    private(set) var ids: Set<UUID>
    private(set) var anchor: UUID?

    init(ids: Set<UUID> = [], anchor: UUID? = nil) {
        self.ids = ids
        self.anchor = anchor
    }

    var isEmpty: Bool { ids.isEmpty }

    /// ⌘ 点击：已在选中集则移除（并清掉对应锚点），否则加入并设为新锚点
    mutating func toggle(_ id: UUID) {
        if ids.contains(id) {
            ids.remove(id)
            if anchor == id { anchor = nil }
        } else {
            ids.insert(id)
            anchor = id
        }
    }

    /// 无修饰键点击：仅选中该条目
    mutating func selectOnly(_ id: UUID) {
        ids = [id]
        anchor = id
    }

    /// Shift 点击：从锚点到点击条目的区间选中（按 `order` 顺序，双向均可）。
    /// 无锚点或锚点/点击条目不在 order 中时退化为 selectOnly。
    mutating func shift(_ id: UUID, order: [UUID]) {
        guard let anchor,
              let a = order.firstIndex(of: anchor),
              let b = order.firstIndex(of: id) else {
            selectOnly(id)
            return
        }
        let range = a <= b ? order[a...b] : order[b...a]
        ids = Set(range)
    }

    mutating func clear() {
        ids = []
        anchor = nil
    }

    /// 条目被移除后同步选中集（批量删除 / 拖出成功后调用）
    mutating func remove(_ removed: Set<UUID>) {
        ids.subtract(removed)
        if let currentAnchor = anchor, removed.contains(currentAnchor) {
            anchor = nil
        }
    }
}

/// 拖拽排序纯逻辑（可单测，V2-6）：drop 命中点换算 + 数组内移动。
enum ReorderLogic {
    /// 把横向面板内 drop 位置的 x 坐标换算为插入目标下标（0...count，count = 追加到末尾）。
    /// 条目定宽 + 等间距 + 统一 leading padding，由几何直接反算目标槽位。
    static func indexForX(
        _ x: CGFloat,
        itemWidth: CGFloat = 150,
        spacing: CGFloat = 10,
        leadingPadding: CGFloat = 10,
        count: Int
    ) -> Int {
        let slot = (x - leadingPadding) / (itemWidth + spacing)
        let index = Int(slot.rounded())
        return min(max(index, 0), count)
    }

    /// SwiftUI move（fromOffsets/toOffset）语义的数组内移动：把 `id` 对应条目移到目标槽位。
    static func moving<T: Identifiable>(_ items: [T], id: T.ID, to target: Int) -> [T] {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return items }
        var result = items
        let item = result.remove(at: from)
        let insertAt = min(max(target, 0), result.count)
        guard insertAt != from else { return items }
        result.insert(item, at: insertAt)
        return result
    }
}
