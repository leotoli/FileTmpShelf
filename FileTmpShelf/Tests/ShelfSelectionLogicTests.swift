import XCTest
@testable import FileTmpShelf

/// V2-6 多选纯逻辑测试：⌘ 切换 / Shift 区间 / 点击替换 / 清空 / 移除同步。
final class ShelfSelectionLogicTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()
    private let d = UUID()
    private var order: [UUID] { [a, b, c, d] }

    func testPlainClickSelectsOnly() {
        var sel = ShelfSelection(ids: [a, b], anchor: a)
        sel.selectOnly(c)
        XCTAssertEqual(sel.ids, [c])
        XCTAssertEqual(sel.anchor, c)
    }

    func testCommandToggleAddsAndSetsAnchor() {
        var sel = ShelfSelection()
        sel.toggle(a)
        XCTAssertEqual(sel.ids, [a])
        XCTAssertEqual(sel.anchor, a)
    }

    func testCommandToggleRemovesAndClearsAnchor() {
        var sel = ShelfSelection(ids: [a], anchor: a)
        sel.toggle(a)
        XCTAssertTrue(sel.isEmpty)
        XCTAssertNil(sel.anchor)
    }

    func testCommandToggleDoesNotClearOtherAnchor() {
        var sel = ShelfSelection(ids: [a, b], anchor: b)
        sel.toggle(a)
        XCTAssertEqual(sel.ids, [b])
        XCTAssertEqual(sel.anchor, b, "移除非锚点条目不应动锚点")
    }

    func testShiftSelectsRangeForward() {
        var sel = ShelfSelection(ids: [a], anchor: a)
        sel.shift(c, order: order)
        XCTAssertEqual(sel.ids, [a, b, c])
    }

    func testShiftSelectsRangeBackward() {
        var sel = ShelfSelection(ids: [c], anchor: c)
        sel.shift(a, order: order)
        XCTAssertEqual(sel.ids, [a, b, c])
    }

    func testShiftWithoutAnchorDegradesToSelectOnly() {
        var sel = ShelfSelection()
        sel.shift(c, order: order)
        XCTAssertEqual(sel.ids, [c], "无锚点 Shift 退化为单选")
    }

    func testShiftWithUnknownIDDegradesToSelectOnly() {
        let unknown = UUID()
        var sel = ShelfSelection(ids: [a], anchor: a)
        sel.shift(unknown, order: order)
        XCTAssertEqual(sel.ids, [unknown], "锚点/点击条目不在 order 中退化为单选")
    }

    func testClear() {
        var sel = ShelfSelection(ids: [a, b, c], anchor: b)
        sel.clear()
        XCTAssertTrue(sel.isEmpty)
        XCTAssertNil(sel.anchor)
    }

    func testRemoveSubtractsAndClearsAnchorIfRemoved() {
        var sel = ShelfSelection(ids: [a, b, c], anchor: b)
        sel.remove([b, d])
        XCTAssertEqual(sel.ids, [a, c])
        XCTAssertNil(sel.anchor, "锚点被移除应清空锚点")
    }

    func testRemoveKeepsAnchorIfNotRemoved() {
        var sel = ShelfSelection(ids: [a, b, c], anchor: a)
        sel.remove([b, c])
        XCTAssertEqual(sel.ids, [a])
        XCTAssertEqual(sel.anchor, a)
    }

    func testEmptySelectionIsEmpty() {
        XCTAssertTrue(ShelfSelection().isEmpty)
        XCTAssertFalse(ShelfSelection(ids: [a]).isEmpty)
    }
}
