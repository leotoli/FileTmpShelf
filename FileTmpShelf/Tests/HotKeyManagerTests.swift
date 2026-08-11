import XCTest
import Carbon.HIToolbox
@testable import FileTmpShelf

/// Spike S3 — 验证 Carbon RegisterEventHotKey 方案：
/// 注册成功、冲突检测（eventHotKeyExistsErr）、解除后可重注册、回调触发。
final class HotKeyManagerTests: XCTestCase {

    /// ⌥X：X = kVK_ANSI_X = 7
    private func makeOptionX() -> HotKeyManager {
        HotKeyManager(keyCode: HotKeyManager.keyCodeForOptionX, modifiers: [.option])
    }

    /// 注册 ⌥X 应返回成功（noErr，不抛错）。
    /// 注意：全局热键是机器级共享资源，若被其他进程占用（如其他 xcodebuild 宿主
    /// 退出延迟残留、用户其他 App），register 抛 hotKeyExists —— 这是环境状态而非
    /// 代码缺陷，此时 XCTSkip 而非失败，保证测试套件在共享热键环境下稳定。
    func testRegisterOptionXReturnsSuccess() throws {
        let manager = makeOptionX()
        defer { manager.unregister() }
        do {
            try manager.register()
        } catch HotKeyManager.RegisterError.hotKeyExists {
            throw XCTSkip("⌥X 被其他进程占用，跳过注册成功验证（环境状态，非代码缺陷）")
        }
    }

    /// 重复注册同一热键应抛 `hotKeyExists`（Carbon eventHotKeyExistsErr = -9878）
    func testDuplicateRegistrationThrowsHotKeyExists() throws {
        let first = makeOptionX()
        do {
            try first.register()
        } catch HotKeyManager.RegisterError.hotKeyExists {
            throw XCTSkip("⌥X 被其他进程占用，无法构造本进程内冲突场景")
        }
        defer { first.unregister() }

        let second = makeOptionX()
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
        let manager = makeOptionX()
        do {
            try manager.register()
        } catch HotKeyManager.RegisterError.hotKeyExists {
            throw XCTSkip("⌥X 被其他进程占用，跳过重注册验证")
        }
        manager.unregister()

        let fresh = makeOptionX()
        defer { fresh.unregister() }
        XCTAssertNoThrow(try fresh.register(), "unregister 后应可重新注册 ⌥X")
    }

    /// 重复调用 unregister 应安全（幂等），不崩溃
    func testUnregisterIsIdempotent() {
        let manager = makeOptionX()
        manager.unregister()
        manager.unregister()
    }

    /// Task 1 — update(keyCode:modifiers:) 重注册：
    /// 旧键（⌥X）被释放可被新实例注册，新键被本实例占用（再次注册抛 hotKeyExists）。
    func testUpdateUnregistersOldKeyAndRegistersNewKey() throws {
        let manager = makeOptionX()
        do {
            try manager.register()
        } catch HotKeyManager.RegisterError.hotKeyExists {
            throw XCTSkip("⌥X 被其他进程占用，跳过 update 重注册验证")
        }
        defer { manager.unregister() }

        // 切换到 ⌥V（V = kVK_ANSI_V = 9）
        let newKeyCode: UInt32 = 9
        do {
            try manager.update(keyCode: newKeyCode, modifiers: [.option])
        } catch HotKeyManager.RegisterError.hotKeyExists {
            throw XCTSkip("⌥V 被其他进程占用，跳过 update 重注册验证")
        }

        // 旧键应已被释放 → ⌥X 可被新实例成功注册
        let probe = makeOptionX()
        defer { probe.unregister() }
        XCTAssertNoThrow(try probe.register(), "update 后旧键 ⌥X 应被释放，可重新注册")

        // 新键应已被本实例占用 → 再次注册 ⌥V 抛 hotKeyExists
        let conflict = HotKeyManager(keyCode: newKeyCode, modifiers: [.option])
        XCTAssertThrowsError(try conflict.register()) { error in
            guard case HotKeyManager.RegisterError.hotKeyExists = error else {
                return XCTFail("update 后新键应被占用，期望 hotKeyExists，实际: \(error)")
            }
        }
    }

    /// 通过 CGEvent 模拟 ⌥X 按键，验证 Carbon 回调触发（后台全局热键语义）。
    ///
    /// ⚠️ 集成测试（非单元测试）：依赖 ①辅助功能权限（AXIsProcessTrusted，按可执行
    /// 文件路径授予，CI/无头环境不可靠）②前台应用不拦截合成事件 ③系统事件派发时序。
    /// 默认跳过（XCTSkip），设置环境变量 FTS_RUN_HOTKEY_INTEGRATION=1 时启用，
    /// 用于本机人工验证。真实用户场景的回调验证见 docs/MANUAL_CHECK_S4.md。
    func testCallbackFiresOnSimulatedOptionX() throws {
        guard ProcessInfo.processInfo.environment["FTS_RUN_HOTKEY_INTEGRATION"] == "1" else {
            throw XCTSkip("集成测试（需辅助功能权限+前台交互），默认跳过；设 FTS_RUN_HOTKEY_INTEGRATION=1 启用")
        }
        guard AXIsProcessTrusted() else {
            throw XCTSkip("缺少辅助功能权限，跳过 CGEvent 模拟按键测试")
        }

        let manager = makeOptionX()
        do {
            try manager.register()
        } catch HotKeyManager.RegisterError.hotKeyExists {
            throw XCTSkip("⌥X 被其他进程占用，跳过回调触发验证")
        }
        defer { manager.unregister() }

        // 排水 run loop：让 Carbon 热键注册在事件循环中稳定生效
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        // 重试投递最多 3 次（每次间隔 0.2s），规避 post 时序竞态。
        // 注意：XCTest 规定 expectation 只能 wait 一次，故每次重试都新建 expectation
        // 并重新设置 onTrigger（onTrigger 是闭包，可被安全覆盖）。
        for attempt in 1...3 {
            let fired = expectation(description: "⌥X 回调触发 (attempt \(attempt))")
            manager.onTrigger = {
                fired.fulfill()
            }
            postOptionXKeyPress()
            let result = XCTWaiter.wait(for: [fired], timeout: 2)
            if result == .completed { return }
            print("[HotKeyManagerTests] 第 \(attempt) 次投递未触发，重试…")
        }
        XCTFail("3 次投递后 ⌥X 回调仍未触发")
    }

    private func postOptionXKeyPress() {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        let keyCode = CGKeyCode(HotKeyManager.keyCodeForOptionX)

        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = .maskAlternate
        down?.post(tap: .cghidEventTap)

        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = .maskAlternate
        up?.post(tap: .cghidEventTap)
    }
}
