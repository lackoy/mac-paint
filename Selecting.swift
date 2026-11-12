import SwiftUI
import AppKit

// Geometry for selecting drawings and images: hit tests, "touching" an area, bounds, moving.

/// Rotates `p` around `c`; positive angles turn clockwise on screen (y-down).
func rotate(_ p: CGPoint, around c: CGPoint, by a: CGFloat) -> CGPoint {
    let dx = p.x - c.x, dy = p.y - c.y
    return CGPoint(x: c.x + dx * cos(a) - dy * sin(a), y: c.y + dx * sin(a) + dy * cos(a))
}

private func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let len2 = dx * dx + dy * dy
    let t = len2 == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

/// Adds points so consecutive ones are at most `step` apart (so small areas still catch long segments).
private func densify(_ pts: [CGPoint], closed: Bool, step: CGFloat = 4) -> [CGPoint] {
    guard pts.count > 1 else { return pts }
    let path = closed ? pts + [pts[0]] : pts
    var out: [CGPoint] = []
    for (a, b) in zip(path, path.dropFirst()) {
        let n = max(1, Int(hypot(b.x - a.x, b.y - a.y) / step))
        for k in 0..<n {
            let t = CGFloat(k) / CGFloat(n)
            out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
    }
    out.append(path.last!)
    return out
}

func textSize(_ s: String, _ width: CGFloat) -> CGSize {
    NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: fontSize(width))]).size()
}

extension Item {
    /// The outline as a polyline (closed for boxes/ellipses/images/text).
    private var outline: (points: [CGPoint], closed: Bool) {
        switch shape {
        case .stroke(let pts):
            return (pts, false)
        case .line(let a, let b), .arrow(let a, let b):
            return ([a, b], false)
        case .rect(let a, let b):
            let r = rectFrom(a, b)
            return ([0, 1, 3, 2].map { cornerPoint(of: r, $0) }, true)
        case .ellipse(let a, let b):
            let r = rectFrom(a, b)
            return ((0..<32).map { k in
                let t = CGFloat(k) / 32 * 2 * .pi
                return CGPoint(x: r.midX + r.width / 2 * cos(t), y: r.midY + r.height / 2 * sin(t))
            }, true)
        case .text(let s, let p):
            let r = CGRect(origin: p, size: textSize(s, width))
            return ([0, 1, 3, 2].map { cornerPoint(of: r, $0) }, true)
        case .image(_, let r):
            return ([0, 1, 3, 2].map { worldCorner(r, angle, $0) }, true)
        }
    }

    /// Text and images count as filled areas; everything else only along its line.
    private var isFilled: Bool {
        switch shape {
        case .text, .image: return true
        default: return false
        }
    }

    var bounds: CGRect {
        let pts = outline.points
        guard let first = pts.first else { return .null }
        var r = CGRect(origin: first, size: .zero)
        for p in pts { r = r.union(CGRect(origin: p, size: .zero)) }
        return isFilled ? r : r.insetBy(dx: -width / 2, dy: -width / 2)
    }

    /// Whether a click at `p` lands on the item.
    /// `slop` is extra click tolerance in world units (shrinks as you zoom in).
    func hit(_ p: CGPoint, slop: CGFloat = 4) -> Bool {
        let (pts, closed) = outline
        if isFilled {
            var path = Path()
            path.addLines(pts)
            path.closeSubpath()
            return path.contains(p)
        }
        let tol = width / 2 + slop
        if pts.count == 1 { return hypot(pts[0].x - p.x, pts[0].y - p.y) <= tol }
        let segs = closed ? pts + [pts[0]] : pts
        return zip(segs, segs.dropFirst()).contains { distance(p, toSegment: $0, $1) <= tol }
    }

    /// Whether any part of the item lies inside the area.
    func touches(_ s: Selection) -> Bool {
        let area = s.path
        let (pts, closed) = outline
        if densify(pts, closed: closed).contains(where: { area.contains($0) }) { return true }
        // An area drawn entirely inside an image or text box.
        let b = area.boundingRect
        return isFilled && hit(CGPoint(x: b.midX, y: b.midY))
    }

    func offsetBy(_ d: CGSize) -> Item {
        let f = { (p: CGPoint) in CGPoint(x: p.x + d.width, y: p.y + d.height) }
        var c = self
        switch shape {
        case .stroke(let pts): c.shape = .stroke(pts.map(f))
        case .line(let a, let b): c.shape = .line(f(a), f(b))
        case .arrow(let a, let b): c.shape = .arrow(f(a), f(b))
        case .rect(let a, let b): c.shape = .rect(f(a), f(b))
        case .ellipse(let a, let b): c.shape = .ellipse(f(a), f(b))
        case .text(let s, let p): c.shape = .text(s, f(p))
        case .image(let img, let r): c.shape = .image(img, r.offsetBy(dx: d.width, dy: d.height))
        }
        return c
    }
}

extension Model {
    /// Bucket-fill layers cover the whole canvas, so they are never selectable.
    private func isSelectable(_ i: Int) -> Bool {
        if case .image = items[i].shape { return items[i].editable }
        return true
    }

    /// Topmost selectable item under `p`.
    func itemIndex(at p: CGPoint) -> Int? {
        items.indices.last { isSelectable($0) && items[$0].hit(p, slop: 4 / zoom) }
    }

    func indices(touching s: Selection) -> Set<Int> {
        Set(items.indices.filter { isSelectable($0) && items[$0].touches(s) })
    }

    /// Box around everything selected.
    var selectionBounds: CGRect? {
        let boxes = selected.filter { $0 < items.count }.map { items[$0].bounds }
        guard let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Drops selected indices that undo/redo made invalid.
    func clampSelectedImage() {
        selected = selected.filter { $0 < items.count && isSelectable($0) }
    }

    /// Delete key. Returns false when nothing is selected, so the key press can pass through.
    func deleteSelected() -> Bool {
        let doomed = selected.filter { $0 < items.count }
        guard !doomed.isEmpty else { return false }
        pushUndo()
        for i in doomed.sorted(by: >) { items.remove(at: i) }
        selected = []
        selection = nil
        return true
    }
}
