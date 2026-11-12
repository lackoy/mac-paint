import SwiftUI
import AppKit

// Infinite canvas with zoom and pan. Items live in "world" coordinates;
// the screen shows them as  screen = world × zoom + pan.

extension Model {
    static let zoomRange: ClosedRange<CGFloat> = 0.05...32

    var viewTransform: CGAffineTransform {
        CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: pan.width, ty: pan.height)
    }

    func toWorld(_ s: CGPoint) -> CGPoint {
        CGPoint(x: (s.x - pan.width) / zoom, y: (s.y - pan.height) / zoom)
    }

    func toScreen(_ p: CGPoint) -> CGPoint { p.applying(viewTransform) }

    func toScreen(_ r: CGRect) -> CGRect { r.applying(viewTransform) }

    /// The part of the world currently visible.
    var viewport: CGRect {
        CGRect(origin: toWorld(.zero), size: CGSize(width: canvasSize.width / zoom, height: canvasSize.height / zoom))
    }

    /// Zooms while keeping the world point under screen point `s` in place.
    func setZoom(_ z: CGFloat, anchor s: CGPoint) {
        let w = toWorld(s)
        zoom = min(max(z, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        pan = CGSize(width: s.x - w.x * zoom, height: s.y - w.y * zoom)
    }

    private var viewCenter: CGPoint { CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2) }

    func zoomIn() { setZoom(zoom * 1.25, anchor: viewCenter) }
    func zoomOut() { setZoom(zoom / 1.25, anchor: viewCenter) }

    func resetZoom() {
        zoom = 1
        pan = .zero
    }
}

private var viewMonitor: Any?

/// Trackpad pinch = zoom at the cursor; scroll = pan; ⌘/⌃ + scroll (mouse wheel) = zoom at the cursor.
@MainActor
func installViewMonitor(_ m: Model) {
    guard viewMonitor == nil else { return }
    viewMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { e in
        guard let window = e.window, window == NSApp.mainWindow, window.attachedSheet == nil,
              let content = window.contentView else { return e }
        var p = content.convert(e.locationInWindow, from: nil)
        if !content.isFlipped { p.y = content.bounds.height - p.y }
        let s = CGPoint(x: p.x - m.canvasFrame.minX, y: p.y - m.canvasFrame.minY)
        guard s.x >= 0, s.y >= 0, s.x <= m.canvasSize.width, s.y <= m.canvasSize.height else { return e }

        if e.type == .magnify {
            m.setZoom(m.zoom * (1 + e.magnification), anchor: s)
        } else if !e.modifierFlags.intersection([.command, .control]).isEmpty {
            let step = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 0.01 : e.scrollingDeltaY * 0.1
            m.setZoom(m.zoom * exp(step), anchor: s)
        } else {
            let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 10
            m.pan.width += e.scrollingDeltaX * k
            m.pan.height += e.scrollingDeltaY * k
        }
        return nil
    }
}

/// Bottom-right "− 100% +" control; clicking the percentage resets to 100%.
struct ZoomControl: View {
    @ObservedObject var m: Model

    var body: some View {
        HStack(spacing: 4) {
            Button { m.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .help("축소 (⌘-)")
            Button { m.resetZoom() } label: {
                Text("\(Int((m.zoom * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(minWidth: 48)
            }
            .help("100%로 (⌘0)")
            Button { m.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .help("확대 (⌘=)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.1)))
        .padding(12)
    }
}
