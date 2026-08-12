import XCTest
@testable import FileTmpShelf

/// V2-7：Quick Look 预览纯逻辑（QuickLookPreviewLogic）。
/// 取舍说明：QLPreviewPanel 是系统单例面板，展示预览依赖真实 GUI 会话，无法在
/// 单元测试中可靠断言；故只测试「初始预览位置」与「方向键切换索引」两个纯函数，
/// 控制器（QuickLookController）的面板交互留待真机验收。
final class QuickLookLogicTests: XCTestCase {
    private let urls: [URL] = [
        URL(fileURLWithPath: "/tmp/a.png"),
        URL(fileURLWithPath: "/tmp/b.pdf"),
        URL(fileURLWithPath: "/tmp/c.txt"),
        URL(fileURLWithPath: "/tmp/d.jpg")
    ]

    // MARK: - initialIndex（多选集中当前预览项）

    func testInitialIndexReturnsFocusedIndex() {
        let focused = URL(fileURLWithPath: "/tmp/c.txt")
        XCTAssertEqual(QuickLookPreviewLogic.initialIndex(urls: urls, focused: focused), 2)
    }

    func testInitialIndexFocusedIsFirst() {
        let focused = URL(fileURLWithPath: "/tmp/a.png")
        XCTAssertEqual(QuickLookPreviewLogic.initialIndex(urls: urls, focused: focused), 0)
    }

    func testInitialIndexFocusedLast() {
        let focused = URL(fileURLWithPath: "/tmp/d.jpg")
        XCTAssertEqual(QuickLookPreviewLogic.initialIndex(urls: urls, focused: focused), 3)
    }

    func testInitialIndexFocusedNotInSetFallsBackToZero() {
        let focused = URL(fileURLWithPath: "/tmp/unknown.xyz")
        XCTAssertEqual(QuickLookPreviewLogic.initialIndex(urls: urls, focused: focused), 0,
                       "焦点条目不在预览集中时回退第一个")
    }

    func testInitialIndexNilFocusFallsBackToZero() {
        XCTAssertEqual(QuickLookPreviewLogic.initialIndex(urls: urls, focused: nil), 0,
                       "无焦点条目时回退第一个")
    }

    func testInitialIndexEmptySetReturnsNil() {
        XCTAssertNil(QuickLookPreviewLogic.initialIndex(urls: [], focused: urls[0]),
                     "无预览项时返回 nil（上层不打开面板）")
    }

    // MARK: - nextIndex（方向键切换，越界钳制不环绕）

    func testNextIndexForward() {
        XCTAssertEqual(QuickLookPreviewLogic.nextIndex(current: 1, count: 4, direction: 1), 2)
    }

    func testNextIndexBackward() {
        XCTAssertEqual(QuickLookPreviewLogic.nextIndex(current: 2, count: 4, direction: -1), 1)
    }

    func testNextIndexClampsAtLastItem() {
        XCTAssertEqual(QuickLookPreviewLogic.nextIndex(current: 3, count: 4, direction: 1), 3,
                       "末尾再向右钳制在原地，不环绕")
    }

    func testNextIndexClampsAtFirstItem() {
        XCTAssertEqual(QuickLookPreviewLogic.nextIndex(current: 0, count: 4, direction: -1), 0,
                       "开头再向左钳制在原地，不环绕")
    }

    func testNextIndexSingleItemAlwaysStays() {
        XCTAssertEqual(QuickLookPreviewLogic.nextIndex(current: 0, count: 1, direction: 1), 0)
        XCTAssertEqual(QuickLookPreviewLogic.nextIndex(current: 0, count: 1, direction: -1), 0)
    }

    func testNextIndexEmptySetReturnsNil() {
        XCTAssertNil(QuickLookPreviewLogic.nextIndex(current: 0, count: 0, direction: 1))
    }

    // MARK: - PreviewSelection（可预览集语义）

    func testPreviewSelectionFocusedID() {
        let id = UUID()
        let selection = PreviewSelection(items: [], focusedID: id)
        XCTAssertEqual(selection.focusedID, id)
        XCTAssertTrue(selection.items.isEmpty)
    }
}
