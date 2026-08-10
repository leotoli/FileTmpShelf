import XCTest
import Carbon.HIToolbox
@testable import FileTmpShelf

/// Spike S3 — 验证 Carbon RegisterEventHotKey 方案：
/// 注册成功、冲突检测（eventHotKeyExistsErr）、解除后可重注册、回调触发。
final class HotKeyManagerTests: XCTestCase {

    /// ⌥C：C = kVK_ANSI_C = 8
    private func makeOptionC() -> HotKeyManager {
        HotKeyManager(keyCode: HotKeyManager.keyCodeForOptionC, modifiers: [.option])
    }

    /// 注册 ⌥C 应返回成功（noErr，不抛错）
    func testRegisterOptionCReturnsSuccess() throws {
        let manager = makeOptionC()
        defer { manager.unregister() }
        XCTAssertNoThrow(try manager.register(), "⌥C 首次注册应成功（noErr）")
    }

    /// 重复注册同一热键应抛 `hotKeyExists`（Carbon eventHotKeyExistsErr = -9878）
    func testDuplicateRegistrationThrowsHotKeyExists() throws {
        let first = makeOptionC()
        try first.register()
        defer { first.unregister() }

        let second = makeOptionC()
        XCTAssertThrowsError(try second.register()) { error in
            guard case HotKeyManager.RegisterError.hotKeyExists = error else {
                return XCTFail("期望 hotKeyExists（eventHotKeyExistsErr 映射），实际: \(error)")
            }
        }
        // 错误文案应为可读提示（SPIKE 5.3：冲突时可给出可读提示）
        XCTAssertEqual(
            HotKeyManager.RegisterError.hotKeyExists.description,
            "快捷键已被其他应用占用"
        )
    }

    /// unregister 后可重新注册同一热键
    func testUnregisterAllowsReRegistration() throws {
        let manager = makeOptionC()
        try manager.register()
        manager.unregister()

        let fresh = makeOptionC()
        defer { fresh.unregister() }
        XCTAssertNoThrow(try fresh.register(), "unregister 后应可重新注册 ⌥C")
    }

    /// 重复调用 unregister 应安全（幂等），不崩溃
    func testUnregisterIsIdempotent() {
        let manager = makeOptionC()
        manager.unregister()
        manager.unregister()
    }

    /// 通过 CGEvent 模拟 ⌥C 按键，验证 Carbon 回调触发（后台全局热键语义）。
    /// 注意：合成键盘事件投递需要「输入监控/辅助功能」权限（AXIsProcessTrusted）。
    /// 无权限时事件会被系统丢弃，因此本用例在无权限环境下跳过（XCTSkip），
    /// 避免在 CI/无头环境挂起；有权限环境下真实验证回调触发。
    func testCallbackFiresOnSimulatedOptionC() throws {
        guard AXIsProcessTrusted() else {
            throw XCTSkip("缺少辅助功能权限，跳过 CGEvent 模拟按键测试（S3 边界条件：有权限时验证）")
        }

        let manager = makeOptionC()
        try manager.register()
        defer { manager.unregister() }

        let fired = expectation(description: "⌥C 回调触发")
        manager.onTrigger = {
            fired.fulfill()
        }

        postOptionCKeyPress()

        wait(for: [fired], timeout: 5)
    }

    private func postOptionCKeyPress() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let keyCode = CGKeyCode(HotKeyManager.keyCodeForOptionC)

        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = .maskAlternate
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = .maskAlternate
        up?.post(tap: .cghidEventTap)
    }
}
