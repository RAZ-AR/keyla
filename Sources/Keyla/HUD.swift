import Cocoa
import SwiftUI

final class HUDModel: ObservableObject {
    @Published var title = ""
    @Published var subtitle: String?
    @Published var badge: String?
    @Published var level: Double?   // microphone level 0...1 while dictating
}

/// Black card, signal circle with the layout code (or a dot), white text. Circle breathes with the voice level.
struct HUDView: View {
    @ObservedObject var model: HUDModel
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(K.signal)
                    .scaleEffect(model.level.map { 0.72 + 0.28 * $0 } ?? 1)
                    .animation(.easeOut(duration: 0.12), value: model.level)
                if let b = model.badge {
                    Text(b).font(K.title(b.count > 2 ? 10 : 12)).foregroundStyle(K.ink)
                } else {
                    Circle().fill(K.ink).frame(width: 9, height: 9).offset(x: -4, y: 4)
                }
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.title).font(K.text(14, .bold)).foregroundStyle(.white).lineLimit(1)
                if let s = model.subtitle {
                    Text(s).font(K.text(12)).foregroundStyle(.white.opacity(0.66)).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: min(320, max(160, CGFloat(s.count) * 6.2)), alignment: .leading)
                }
            }
        }
        .padding(.leading, 8).padding(.trailing, 16).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(K.ink))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// Small floating bubble near the text caret (or the mouse) — layout, typos, dictation status.
final class HUD {
    static let shared = HUD()
    let model = HUDModel()
    private let panel: NSPanel
    private let host: NSHostingView<HUDView>
    private var hideWork: DispatchWorkItem?

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        host = NSHostingView(rootView: HUDView(model: model))
        panel.contentView = host
    }

    /// duration nil = stays until hide()
    func show(_ title: String, _ subtitle: String? = nil, badge: String? = nil, level: Double? = nil, duration: Double? = 1.4, force: Bool = false) {
        guard force || Settings.showHUD else { return }
        model.title = title
        model.badge = badge
        model.subtitle = subtitle
        model.level = level
        let size = host.fittingSize
        let anchor = AX.caretRect()
        var origin: NSPoint
        if let a = anchor {
            origin = NSPoint(x: a.minX, y: a.minY - size.height - 6)
        } else {
            let m = NSEvent.mouseLocation
            origin = NSPoint(x: m.x + 14, y: m.y - size.height - 14)
        }
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main {
            let f = screen.visibleFrame
            origin.x = min(max(origin.x, f.minX + 4), f.maxX - size.width - 4)
            if origin.y < f.minY { origin.y = (anchor?.maxY ?? origin.y) + 6 }
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideWork?.cancel()
        if let duration {
            let w = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: w)
        }
    }

    func updateLevel(_ l: Double) { model.level = l }

    func hide() {
        hideWork?.cancel()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.18
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in panel.orderOut(nil) })
    }
}
