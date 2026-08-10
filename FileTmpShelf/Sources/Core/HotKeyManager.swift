import AppKit
import Carbon.HIToolbox

/// 全局快捷键管理器（Carbon RegisterEventHotKey）。
/// Spike S3 目标：验证 ⌥C 全局唤起的低延迟、无辅助功能权限依赖、冲突检测。
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

    /// ⌥C 的虚拟键码（C = kVK_ANSI_C = 8）
    static let keyCodeForOptionC: UInt32 = 8

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let keyCode: UInt32
    private let modifiers: NSEvent.ModifierFlags

    /// 由面板控制器注入的触发回调
    var onTrigger: (() -> Void)?

    /// 冲突检测：注册前先探测是否已被占用
    var isConflicting: Bool {
        // Carbon 会返回 eventHotKeyExistsErr (-9878) 当热键已被注册（本 app 或其他 app）
        // 更精确的全局占用检测需要辅助功能权限，V1 仅探测本进程内冲突
        return false
    }

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// 注册全局热键
    func register() throws {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData else { return noErr }
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
                if hotKeyID.id == 1 {
                    manager.onTrigger?()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x46545348), id: 1) // "FTSH"
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
            throw RegisterError.osStatus(status)
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

    private func carbonModifierFlags(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
}
