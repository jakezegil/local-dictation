import Carbon
import Foundation

final class EscapeKey {
    private let onEscape: () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static let identifier = EventHotKeyID(signature: 0x4c444553, id: 1)

    init(onEscape: @escaping () -> Void) { self.onEscape = onEscape }
    deinit { stop() }

    func register() throws {
        stop()
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == EscapeKey.identifier.signature,
                  identifier.id == EscapeKey.identifier.id else { return OSStatus(eventNotHandledErr) }
            Unmanaged<EscapeKey>.fromOpaque(context).takeUnretainedValue().onEscape()
            return noErr
        }, 1, &type, context, &handler)
        guard result == noErr else { throw shortcutError(result) }
        let registration = RegisterEventHotKey(UInt32(kVK_Escape), 0, Self.identifier,
                                                GetApplicationEventTarget(), 0, &hotKey)
        guard registration == noErr else {
            stop()
            throw shortcutError(registration)
        }
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }

    private func shortcutError(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [
            NSLocalizedDescriptionKey: "The Escape cancellation shortcut could not be registered."
        ])
    }
}
