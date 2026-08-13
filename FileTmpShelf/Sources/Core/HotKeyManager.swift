import AppKit
import Carbon

/// 全局快捷键管理器（Carbon RegisterEventHotKey）。
/// Spike S3 目标：验证 ⌥X 全局唤起的低延迟、无辅助功能权限依赖、冲突检测。
final class HotKeyManager {
    enum RegisterError: Error, CustomStringConvertible {
        case hotKeyExists
        case osStatus(OSStatus)

        var description: String {
            switch self {
            case .hotKeyExists: return "快捷键已被其他应用占用"
            case .osStatus(let code): return "注册失败 (OSStatus \(code))"
            }
        }
    }

    /// ⌥X 的虚拟键码（X = kVK_ANSI_X = 7）
    static let keyCodeForOptionX: UInt32 = 7

    /// ⌘↩ 跳转访达（V5-1）的键码：kVK_Return = 36
    static let keyCodeForReturn: UInt32 = 36

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var keyCode: UInt32
    private var modifiers: NSEvent.ModifierFlags
    /// Carbon 热键唯一 id（signature "FTSH" 下的子 id）；⌥X 用 1，⌘↩ 用 2，避免冲突
    private let hotKeyIDValue: UInt32

    /// 由面板控制器注入的触发回调。
    /// 注意：Carbon 热键事件在主线程派发，因此 onTrigger 总是被调用在主线程。
    var onTrigger: (() -> Void)?

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags, hotKeyID: UInt32 = 1) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.hotKeyIDValue = hotKeyID
    }

    /// 冲突检测：通过 register() 抛出的 `RegisterError.hotKeyExists` 识别。
    /// Carbon 的 `RegisterEventHotKey` 在热键已被注册（本 app 或其他 app）时
    /// 返回 `eventHotKeyExistsErr` (-9878)，无需辅助功能权限即可可靠检测本进程内冲突。
    /// 更精确的「全系统占用清单」检测需要辅助功能权限，V1 不做。

    /// 注册全局热键。
    /// - 安装事件处理器失败（InstallEventHandler 非 noErr）时抛出 `osStatus`
    /// - 热键已被占用（RegisterEventHotKey 返回 eventHotKeyExistsErr）时抛出 `hotKeyExists`
    /// - 其余非 noErr 状态码抛出 `osStatus`
    /// register() 是原子的：失败时会回滚已安装的事件处理器，可安全重试。
    func register() throws {
        if eventHandlerRef == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            )

            let installStatus = InstallEventHandler(
                GetApplicationEventTarget(),
                { (_, event, userData) -> OSStatus in
                    guard let userData else { return OSStatus(eventNotHandledErr) }
                    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                    var hotKeyID = EventHotKeyID()
                    GetEventParameter(
                        event,
                        EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID),
                        nil,
                        MemoryLayout<EventHotKeyID>.size,
                        nil,
                        &hotKeyID
                    )
                    if hotKeyID.id == manager.hotKeyIDValue {
                        manager.onTrigger?()
                        return noErr
                    }
                    // 关键：不匹配时返回 eventNotHandledErr，让事件继续派发到
                    // 其他热键处理器。否则本处理器消费事件，后注册的热键（如 ⌘↩）
                    // 永远收不到，导致 ⌥X/⌘↩ 互相干扰（用户反馈「无法关闭货架」）。
                    return OSStatus(eventNotHandledErr)
                },
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                &eventHandlerRef
            )
            guard installStatus == noErr else {
                eventHandlerRef = nil
                throw RegisterError.osStatus(installStatus)
            }
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x46545348), id: hotKeyIDValue) // "FTSH"
        let carbonModifiers = carbonModifierFlags(from: modifiers)
        let status = RegisterEventHotKey(
            keyCode,
            carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard status == noErr else {
            // 回滚：去掉本 call 安装的事件处理器，保证 register() 原子性
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
                self.eventHandlerRef = nil
            }
            throw status == eventHotKeyExistsErr
                ? RegisterError.hotKeyExists
                : RegisterError.osStatus(status)
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    /// 运行时切换快捷键（设置窗口「录制」后调用）：
    /// unregister 旧键 → 记录新键 → register 新键。
    /// 若新键已被其他进程占用则抛 `RegisterError.hotKeyExists`，此时旧键已释放、
    /// 新键未占用（保持可读错误，不崩溃），调用方据此提示冲突。
    func update(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) throws {
        unregister()
        self.keyCode = keyCode
        self.modifiers = modifiers
        try register()
    }

    deinit {
        // 防止用户数据指针悬挂：管理器释放前必须先移除 Carbon 事件处理器。
        unregister()
    }

    private func carbonModifierFlags(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    // MARK: - 展示

    /// 把键码 + 修饰符格式化为可读组合（如 "⌥X"），供菜单栏标题 / 录制 UI 显示。
    static func displayString(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) -> String {
        let symbols: [(NSEvent.ModifierFlags, String)] = [
            (.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")
        ]
        let prefix = symbols.filter { modifiers.contains($0.0) }.map(\.1).joined()
        return prefix + (character(forKeyCode: keyCode) ?? "键码\(keyCode)")
    }

    /// 通过当前键盘布局把虚拟键码转成单字符（kUCKeyActionDisplay，无修饰键）。
    private static func character(forKeyCode keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else {
            return nil
        }
        guard let layoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let data = unsafeBitCast(layoutData, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { $0 }

        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        var deadKeyState: UInt32 = 0
        let status = UCKeyTranslate(
            layout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: length)
    }
}
