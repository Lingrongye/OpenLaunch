import AppKit
import Carbon
final class ShortcutController {
    static let labels = ["⌃⌥Space", "⌘⇧Space", "⌃⇧Space"]
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onActivate: (() -> Void)?
    private(set) var status = ""
    func start() {
        stop()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerResult = InstallEventHandler(GetApplicationEventTarget(), { _, _, ref in
            guard let ref else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<ShortcutController>.fromOpaque(ref).takeUnretainedValue()
            owner.onActivate?(); return noErr
        }, 1, &event, pointer, &handler)
        let index = max(0, min(2, UserDefaults.standard.integer(forKey: "OpenLaunch.shortcut")))
        let modifiers = [controlKey | optionKey, cmdKey | shiftKey, controlKey | shiftKey][index]
        let result = RegisterEventHotKey(UInt32(kVK_Space), UInt32(modifiers), EventHotKeyID(signature: 0x4f4c4e43, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        status = result == noErr && handlerResult == noErr ? "\(Self.labels[index]) 已注册" : "快捷键注册失败或冲突：\(result)/\(handlerResult)"
    }
    func stop() { if let hotKey { UnregisterEventHotKey(hotKey) }; if let handler { RemoveEventHandler(handler) }; hotKey = nil; handler = nil }
    deinit { stop() }
}
