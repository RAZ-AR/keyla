import Cocoa
import ApplicationServices

/// Marker put on every event Keyla posts, so its own event tap ignores them.
let kSyntheticMarker: Int64 = 0x4B45594C

enum TextInjector {
    private static let source = CGEventSource(stateID: .privateState)

    static func key(_ code: CGKeyCode, flags: CGEventFlags = []) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: kSyntheticMarker)
            e.post(tap: .cghidEventTap)
        }
    }

    static func backspace(_ n: Int) { for _ in 0..<max(0, n) { key(51) } }

    /// Types text independent of the active layout.
    static func type(_ text: String) {
        for ch in text {
            let units = Array(String(ch).utf16)
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                e.flags = []
                units.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
                e.setIntegerValueField(.eventSourceUserData, value: kSyntheticMarker)
                e.post(tap: .cghidEventTap)
            }
        }
    }

    static func replace(deleting n: Int, with text: String) {
        backspace(n)
        type(text)
    }

    // MARK: Clipboard-based paste (for long text: dictation, AI rewrites)

    static func paste(_ text: String) {
        let pb = NSPasteboard.general
        let saved = pb.pasteboardItems?.map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { t in item.data(forType: t).map { (t, $0) } })
        } ?? []
        pb.clearContents()
        pb.setString(text, forType: .string)
        key(9, flags: .maskCommand) // ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            pb.clearContents()
            let items = saved.map { dict -> NSPasteboardItem in
                let it = NSPasteboardItem()
                for (t, data) in dict { it.setData(data, forType: t) }
                return it
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
    }

    /// Selected text: Accessibility first, ⌘C fallback for apps that don't expose it.
    static func selectedText(completion: @escaping (String?) -> Void) {
        if let s = AX.selectedText(), !s.isEmpty { completion(s); return }
        let pb = NSPasteboard.general
        let before = pb.changeCount
        let saved = pb.string(forType: .string)
        key(8, flags: .maskCommand) // ⌘C
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard pb.changeCount != before, let s = pb.string(forType: .string), !s.isEmpty else { completion(nil); return }
            if let saved { pb.clearContents(); pb.setString(saved, forType: .string) }
            completion(s)
        }
    }
}

enum AX {
    static func focused() -> AXUIElement? {
        let sys = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(sys, 0.15)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &v) == .success, let v else { return nil }
        return (v as! AXUIElement)
    }

    static func selectedText() -> String? {
        guard let el = focused() else { return nil }
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextAttribute as CFString, &v) == .success else { return nil }
        return v as? String
    }

    static func isSecureField() -> Bool {
        guard let el = focused() else { return false }
        var v: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXSubroleAttribute as CFString, &v)
        return (v as? String) == (kAXSecureTextFieldSubrole as String)
    }

    /// Caret rectangle in Cocoa screen coordinates, if the app exposes it.
    static func caretRect() -> NSRect? {
        guard let el = focused() else { return nil }
        var rangeV: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXSelectedTextRangeAttribute as CFString, &rangeV) == .success,
              let rangeV else { return nil }
        var boundsV: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString,
                                                         rangeV, &boundsV) == .success, let boundsV else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(boundsV as! AXValue, .cgRect, &r), r.width >= 0, r.origin != .zero else { return nil }
        let h = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(x: r.minX, y: h - r.maxY, width: max(r.width, 1), height: max(r.height, 1))
    }
}
