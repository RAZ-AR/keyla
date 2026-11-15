import Carbon
import Cocoa

/// One physical keystroke. Stored as a key code, so the same strokes can be
/// re-read in any keyboard layout ("ghbdtn" <-> "привет").
struct Stroke {
    let keyCode: UInt16
    let shift: Bool
    let caps: Bool
}

func tisProp<T>(_ src: TISInputSource, _ key: CFString) -> T? {
    guard let p = TISGetInputSourceProperty(src, key) else { return nil }
    return Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue() as? T
}

/// A keyboard layout with its key code -> character tables, built from the
/// layout data macOS itself uses (works for US, ABC, Russian, Russian-PC, Ukrainian, ...).
final class KeyLayout {
    let id: String
    let name: String
    let lang: String
    let source: TISInputSource
    private(set) var normal: [UInt16: String] = [:]
    private(set) var shifted: [UInt16: String] = [:]
    private var reverse: [String: (UInt16, Bool)] = [:]

    static let charKeyCodes: [UInt16] = (0...50).filter { ![36, 48, 49].contains($0) }.map { UInt16($0) }

    init?(source: TISInputSource) {
        guard let id: String = tisProp(source, kTISPropertyInputSourceID) else { return nil }
        self.id = id
        self.source = source
        self.name = tisProp(source, kTISPropertyLocalizedName) ?? id
        let langs: [String] = tisProp(source, kTISPropertyInputSourceLanguages) ?? []
        self.lang = langs.first.map { String($0.prefix(2)) } ?? "en"

        guard let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        for kc in KeyLayout.charKeyCodes {
            let n = Self.translate(layout, kc, shift: false)
            let s = Self.translate(layout, kc, shift: true)
            if !n.isEmpty { normal[kc] = n; if reverse[n] == nil { reverse[n] = (kc, false) } }
            if !s.isEmpty { shifted[kc] = s; if reverse[s] == nil { reverse[s] = (kc, true) } }
        }
    }

    private static func translate(_ layout: UnsafePointer<UCKeyboardLayout>, _ kc: UInt16, shift: Bool) -> String {
        var dead: UInt32 = 0
        var len = 0
        var chars = [UniChar](repeating: 0, count: 8)
        let mods: UInt32 = shift ? (UInt32(shiftKey) >> 8) & 0xFF : 0
        let st = UCKeyTranslate(layout, kc, UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()),
                                OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &len, &chars)
        guard st == noErr, len > 0 else { return "" }
        let s = String(utf16CodeUnits: chars, count: len)
        return s.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7F } ? s : ""
    }

    var short: String { lang.uppercased() }
    var flag: String {
        ["en": "🇺🇸", "ru": "🇷🇺", "uk": "🇺🇦", "de": "🇩🇪", "fr": "🇫🇷", "es": "🇪🇸", "it": "🇮🇹",
         "be": "🇧🇾", "kk": "🇰🇿", "hy": "🇦🇲", "ka": "🇬🇪", "pl": "🇵🇱", "tr": "🇹🇷", "he": "🇮🇱", "sr": "🇷🇸", "uz": "🇺🇿", "az": "🇦🇿", "ja": "🇯🇵", "zh": "🇨🇳", "ko": "🇰🇷"][lang] ?? "⌨️"
    }

    func hasKey(_ kc: UInt16) -> Bool { normal[kc] != nil }

    func char(_ s: Stroke) -> String {
        let c = (s.shift ? shifted[s.keyCode] : normal[s.keyCode]) ?? ""
        return s.caps ? c.uppercased() : c
    }

    func text(_ strokes: [Stroke]) -> String { strokes.map(char).joined() }

    /// How many letters of `text` this layout can type.
    func coverage(_ text: String) -> Int {
        text.reduce(0) { acc, ch in
            ch.isLetter && reverse[String(ch)] != nil ? acc + 1 : acc
        }
    }

    static func convert(_ text: String, from a: KeyLayout, to b: KeyLayout) -> String {
        text.map { ch -> String in
            let s = String(ch)
            if let (kc, sh) = a.reverse[s], let out = sh ? b.shifted[kc] : b.normal[kc] { return out }
            return s
        }.joined()
    }
}

final class LayoutManager {
    static let shared = LayoutManager()
    private(set) var layouts: [KeyLayout] = []
    private var cache: [String: KeyLayout] = [:]

    func reload() {
        let filter = [kTISPropertyInputSourceType as String: kTISTypeKeyboardLayout as String] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] else { return }
        layouts = list.compactMap { KeyLayout(source: $0) }
        for l in layouts { cache[l.id] = l }
    }

    /// Any installed layout by id, even if it is not enabled (used by the self-test).
    func installed(id: String) -> KeyLayout? {
        if let l = cache[id] { return l }
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let src = list.first, let l = KeyLayout(source: src) else { return nil }
        cache[id] = l
        return l
    }

    var current: KeyLayout? {
        let src = TISCopyCurrentKeyboardLayoutInputSource().takeRetainedValue()
        guard let id: String = tisProp(src, kTISPropertyInputSourceID) else { return nil }
        if let l = cache[id] { return l }
        let l = KeyLayout(source: src)
        cache[id] = l
        return l
    }

    /// The layout to switch to: the user's chosen partner, else the first enabled layout in another language.
    func alternate(for cur: KeyLayout) -> KeyLayout? { alternates(for: cur).first }

    /// Other layouts in priority order: user's pair first, then English ⇄ Russian/Ukrainian, then the rest.
    func alternates(for cur: KeyLayout) -> [KeyLayout] {
        let pref = Settings.pairedLayouts
        if pref.count == 2, pref.contains(cur.id), let other = pref.first(where: { $0 != cur.id }),
           let l = layouts.first(where: { $0.id == other }) {
            return [l]
        }
        let priority = cur.lang == "en" ? ["ru", "uk", "be"] : ["en"]
        var seen = Set([cur.lang])
        return layouts.filter { $0.lang != cur.lang }
            .sorted { (priority.firstIndex(of: $0.lang) ?? 99) < (priority.firstIndex(of: $1.lang) ?? 99) }
            .filter { seen.insert($0.lang).inserted }
    }

    func layout(withID id: String) -> KeyLayout? { layouts.first { $0.id == id } ?? cache[id] }

    func select(_ l: KeyLayout) { TISSelectInputSource(l.source) }
}
