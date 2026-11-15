import Cocoa
import SwiftUI

/// Keyla design system — Swiss minimalism: one signal colour, ink, paper, giant circles, tight grotesk, huge numerals.
enum K {
    // Colour roles (contrast checked: ink on signal 5.3:1, ink on paper 13.2:1, muted on paper 4.65:1)
    static let signal = Color(red: 0.937, green: 0.290, blue: 0.180)    // #EF4A2E — the one accent
    static let ink = Color(red: 0.051, green: 0.051, blue: 0.051)       // #0D0D0D
    static let paper = Color(red: 0.855, green: 0.831, blue: 0.796)     // #DAD4CB
    static let muted = Color(red: 0.369, green: 0.353, blue: 0.333)     // #5E5A55 — secondary text on paper
    static let rule = Color.black.opacity(0.14)                          // hairlines
    static let nsSignal = NSColor(red: 0.937, green: 0.290, blue: 0.180, alpha: 1)
    static let nsInk = NSColor(red: 0.051, green: 0.051, blue: 0.051, alpha: 1)

    // Type: Helvetica Neue — bold for titles, light for giant numerals, regular for text.
    static func title(_ size: CGFloat) -> Font { .custom("Helvetica Neue", size: size).weight(.bold) }
    static func numeral(_ size: CGFloat) -> Font { .custom("Helvetica Neue", size: size).weight(.light) }
    static func text(_ size: CGFloat = 14, _ w: Font.Weight = .regular) -> Font { .custom("Helvetica Neue", size: size).weight(w) }

    // Spacing scale (8-based) and motion
    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 16, s4: CGFloat = 24, s5: CGFloat = 32
    static let quick = Animation.easeOut(duration: 0.16)
}

/// The Keyla mark: a big ink circle with a small signal "dot" — the caret that hops between layouts.
struct KeylaMark: View {
    var size: CGFloat = 64
    var dot: Color = K.signal
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Circle().fill(K.ink)
            Circle().fill(dot)
                .frame(width: size * 0.3, height: size * 0.3)
                .offset(x: size * 0.2, y: -size * 0.14)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Toggle as a circle: filled ink = on, hairline ring = off.
struct CircleToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { withAnimation(K.quick) { configuration.isOn.toggle() } } label: {
            HStack(spacing: K.s3) {
                configuration.label.font(K.text(14)).foregroundStyle(K.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ZStack {
                    Circle().strokeBorder(K.ink, lineWidth: 1.5)
                    Circle().fill(K.ink).scaleEffect(configuration.isOn ? 1 : 0.001)
                    Circle().fill(K.signal).frame(width: 8, height: 8)
                        .offset(x: -4, y: 4).opacity(configuration.isOn ? 1 : 0)
                }
                .frame(width: 24, height: 24)
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(configuration.isOn ? "включено" : "выключено")
    }
}

/// Text options in a row; the chosen one sits in an ink capsule.
struct OptionRow<T: Hashable>: View {
    let title: String
    @Binding var value: T
    let options: [(String, T)]
    var body: some View {
        VStack(alignment: .leading, spacing: K.s2) {
            Text(title).font(K.text(12, .medium)).foregroundStyle(K.muted)
            FlowRow {
                ForEach(options.indices, id: \.self) { i in
                    let (label, v) = options[i]
                    let on = v == value
                    Button { withAnimation(K.quick) { value = v } } label: {
                        Text(label).font(K.text(13, on ? .bold : .regular))
                            .foregroundStyle(on ? K.paper : K.ink)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(on ? K.ink : .clear))
                            .fixedSize()
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .padding(.vertical, 10)
    }
}

/// Wrapping horizontal layout for option chips.
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, w: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height); w = max(w, x)
        }
        return CGSize(width: min(w, maxW), height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}

/// Text field on a hairline, no box.
struct LineField: View {
    let title: String
    @Binding var text: String
    var secure = false
    var placeholder = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(K.text(12, .medium)).foregroundStyle(K.muted)
            Group {
                if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
            }
            .textFieldStyle(.plain).font(K.text(14)).foregroundStyle(K.ink)
            .accessibilityLabel(title)
            Rectangle().fill(K.ink).frame(height: 1)
        }
        .padding(.vertical, 10)
    }
}

/// Multi-line list editor on a hairline frame.
struct LineEditor: View {
    let title: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(K.text(12, .medium)).foregroundStyle(K.muted)
            TextEditor(text: $text)
                .font(.system(size: 13, design: .monospaced)).foregroundStyle(K.ink)
                .scrollContentBackground(.hidden)
                .padding(8).frame(height: 96)
                .overlay(Rectangle().strokeBorder(K.ink.opacity(0.3)))
                .accessibilityLabel(title)
        }
        .padding(.vertical, 10)
    }
}

struct Rule: View { var body: some View { Rectangle().fill(K.rule).frame(height: 1) } }

/// The big round action from the reference ("More") — black text on signal for AA contrast.
struct CircleButtonStyle: ButtonStyle {
    var size: CGFloat = 92
    var fill: Color = K.signal
    var label: Color = K.ink
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(K.title(15)).foregroundStyle(label)
            .frame(width: size, height: size)
            .background(Circle().fill(fill))
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(enabled ? 1 : 0.35)
            .animation(K.quick, value: configuration.isPressed)
            .contentShape(Circle())
    }
}

struct TextLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(K.text(14, .medium)).foregroundStyle(K.ink)
            .opacity(configuration.isPressed ? 0.5 : 1)
            .padding(.vertical, 6).contentShape(Rectangle())
    }
}

/// Daily counters for the giant numerals.
enum Stats {
    static func key(_ name: String, _ date: Date = Date()) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return "stat.\(name).\(f.string(from: date))"
    }
    static func bump(_ name: String) {
        let k = key(name)
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: k) + 1, forKey: k)
    }
}

/// Menu bar glyph: the Keyla mark as a template image (adapts to light/dark menu bar).
enum MenuGlyph {
    static func image(height: CGFloat = 16) -> NSImage {
        let img = NSImage(size: NSSize(width: height, height: height), flipped: false) { r in
            let big = NSBezierPath(ovalIn: r.insetBy(dx: 0.5, dy: 0.5))
            let d = r.width * 0.34
            let hole = NSBezierPath(ovalIn: NSRect(x: r.width * 0.16, y: r.height * 0.14, width: d, height: d))
            big.append(hole)
            big.windingRule = .evenOdd
            NSColor.black.setFill()
            big.fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}
