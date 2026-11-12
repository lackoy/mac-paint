import SwiftUI
import AppKit
import UniformTypeIdentifiers

private let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

/// Area drawn with the 사각형/자유형 선택 tools, in canvas coordinates.
enum Selection {
    case rect(CGRect)
    case lasso([CGPoint])

    var path: Path {
        switch self {
        case .rect(let r):
            return Path(r)
        case .lasso(let pts):
            var p = Path()
            p.addLines(pts)
            p.closeSubpath()
            return p
        }
    }
}

enum ImageOp: Equatable {
    case rotateRight, rotateLeft, rotate180, flipH, flipV  // the rotations are applied as Item.angle, not pixels
    case resizeSkew(sx: CGFloat, sy: CGFloat, skewX: CGFloat, skewY: CGFloat) // skew in degrees
}

// MARK: - CoreGraphics helpers

func makeContext(_ w: Int, _ h: Int, opaque: Bool) -> CGContext? {
    guard w > 0, h > 0,
          let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high
    if opaque {
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    }
    return ctx
}

/// Applies a geometric transform; the output is sized to the transformed bounds.
func apply(_ op: ImageOp, to img: CGImage, opaque: Bool) -> CGImage? {
    let src = CGRect(x: 0, y: 0, width: img.width, height: img.height)
    let t: CGAffineTransform
    switch op {
    case .rotateRight: t = CGAffineTransform(rotationAngle: -.pi / 2) // CG is y-up: negative = clockwise
    case .rotateLeft: t = CGAffineTransform(rotationAngle: .pi / 2)
    case .rotate180: t = CGAffineTransform(rotationAngle: .pi)
    case .flipH: t = CGAffineTransform(scaleX: -1, y: 1)
    case .flipV: t = CGAffineTransform(scaleX: 1, y: -1)
    case .resizeSkew(let sx, let sy, let kx, let ky):
        let shear = CGAffineTransform(a: 1, b: tan(ky * .pi / 180), c: tan(kx * .pi / 180), d: 1, tx: 0, ty: 0)
        t = CGAffineTransform(scaleX: sx, y: sy).concatenating(shear)
    }
    let bbox = src.applying(t)
    let w = Int(bbox.width.rounded()), h = Int(bbox.height.rounded())
    guard w <= 16000, h <= 16000, let ctx = makeContext(w, h, opaque: opaque) else { return nil }
    ctx.concatenate(CGAffineTransform(translationX: -bbox.minX, y: -bbox.minY))
    ctx.concatenate(t)
    ctx.draw(img, in: src)
    return ctx.makeImage()
}

// MARK: - Selection drags (move / corner resize / rotate)

/// Corner index: 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right (of the unrotated rect).
func cornerPoint(of r: CGRect, _ c: Int) -> CGPoint {
    CGPoint(x: c % 2 == 0 ? r.minX : r.maxX, y: c < 2 ? r.minY : r.maxY)
}

/// Screen position of corner `c` of an image box `r` rotated by `angle` around its center.
func worldCorner(_ r: CGRect, _ angle: CGFloat, _ c: Int) -> CGPoint {
    rotate(cornerPoint(of: r, c), around: CGPoint(x: r.midX, y: r.midY), by: angle)
}

enum ImageDrag {
    case move(snapshot: [Item])
    case resize(index: Int, from: CGRect, corner: Int, snapshot: [Item])
    case rotate(index: Int, from: CGRect, startAngle: CGFloat, snapshot: [Item])
}

/// What a mouse-down at a point would grab (also drives the hover cursor).
enum HoverZone {
    case resize(Int), rotate, move
}

private let rotateCursor: NSCursor = {
    let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .bold)
    guard let img = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return .crosshair }
    return NSCursor(image: img, hotSpot: NSPoint(x: img.size.width / 2, y: img.size.height / 2))
}()

func cursor(for zone: HoverZone?) -> NSCursor {
    switch zone {
    case .resize(let c)?:
        if #available(macOS 15.0, *) {
            let positions: [NSCursor.FrameResizePosition] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
            return .frameResize(position: positions[c], directions: .all)
        }
        return .crosshair
    case .rotate?: return rotateCursor
    case .move?: return .openHand
    case nil: return .arrow
    }
}

private func normalized(_ a: CGFloat) -> CGFloat { atan2(sin(a), cos(a)) }

extension Model {
    /// Selection tools only. A single selected image has corner handles (resize) and a rotate zone just
    /// outside each corner. With 사각형 선택, pressing on the selection or on any item moves it
    /// (hold ⌥ to draw an area instead, e.g. to crop part of an image).
    func hoverZone(at p: CGPoint) -> HoverZone? {
        guard tool.isSelection else { return nil }
        if let i = selectedImage, let r = selectedImageRect {
            let a = items[i].angle
            let near = { (d: CGFloat) in (0..<4).first { hypot(worldCorner(r, a, $0).x - p.x, worldCorner(r, a, $0).y - p.y) <= d } }
            // Handle sizes are in screen points, so convert them to world units.
            if let c = near(8 / zoom) { return .resize(c) }
            let local = rotate(p, around: CGPoint(x: r.midX, y: r.midY), by: -a)
            if !r.contains(local), near(26 / zoom) != nil { return .rotate }
        }
        guard tool == .select, !NSEvent.modifierFlags.contains(.option) else { return nil }
        return selectionBounds?.contains(p) == true || itemIndex(at: p) != nil ? .move : nil
    }

    /// Decides at mouse-down whether this drag edits the selection; nil means normal tool behavior.
    func beginImageDrag(at p: CGPoint) -> ImageDrag? {
        switch hoverZone(at: p) {
        case .resize(let c)?:
            guard let i = selectedImage, let r = selectedImageRect else { return nil }
            return .resize(index: i, from: r, corner: c, snapshot: items)
        case .rotate?:
            guard let i = selectedImage, let r = selectedImageRect else { return nil }
            return .rotate(index: i, from: r, startAngle: items[i].angle, snapshot: items)
        case .move?:
            if selectionBounds?.contains(p) != true, let i = itemIndex(at: p) { selected = [i] }
            selection = nil
            return .move(snapshot: items)
        case nil:
            return nil
        }
    }

    func continueImageDrag(start: CGPoint, loc: CGPoint) {
        switch imageDrag {
        case .move(let snap):
            let d = CGSize(width: loc.x - start.x, height: loc.y - start.y)
            for i in selected where i < snap.count { items[i] = snap[i].offsetBy(d) }
        case .resize(let i, let r, let c, _):
            // Work in the image's own (unrotated) frame. The opposite corner stays fixed;
            // Shift keeps the aspect ratio; near-square snaps to a square.
            let center = CGPoint(x: r.midX, y: r.midY), a = items[i].angle
            let l = rotate(loc, around: center, by: -a)
            let fixed = cornerPoint(of: r, 3 - c)
            let dirX: CGFloat = c % 2 == 0 ? -1 : 1, dirY: CGFloat = c < 2 ? -1 : 1
            var w = max(4, (l.x - fixed.x) * dirX), h = max(4, (l.y - fixed.y) * dirY)
            var square = false
            if NSEvent.modifierFlags.contains(.shift) {
                let s = max(w / r.width, h / r.height)
                w = r.width * s
                h = r.height * s
            } else if abs(w - h) <= 8 / zoom {
                w = (w + h) / 2
                h = w
                square = true
            }
            if snappedSquare != square { snappedSquare = square }
            let local = CGRect(x: dirX > 0 ? fixed.x : fixed.x - w, y: dirY > 0 ? fixed.y : fixed.y - h, width: w, height: h)
            setImageRect(i, place(local, in: r, angle: a))
        case .rotate(let i, let r, let a0, _):
            // Angle swept around the image center since mouse-down; Shift snaps the result to 15° steps.
            let c = CGPoint(x: r.midX, y: r.midY)
            var a = normalized(a0 + atan2(loc.y - c.y, loc.x - c.x) - atan2(start.y - c.y, start.x - c.x))
            if NSEvent.modifierFlags.contains(.shift) {
                let step = CGFloat.pi / 12
                a = normalized((a / step).rounded() * step)
            }
            items[i].angle = a
        case nil:
            break
        }
    }

    /// Records one undo step if the drag actually changed something.
    func endImageDrag() {
        switch imageDrag {
        case .move(let snap):
            if let i = selected.first, i < snap.count, items[i].bounds != snap[i].bounds { pushUndo(snap) }
        case .resize(let i, let r, _, let snap):
            if imageParts(i)?.1 != r { pushUndo(snap) }
        case .rotate(let i, _, let a0, let snap):
            if items[i].angle != a0 { pushUndo(snap) }
        case nil:
            break
        }
        snappedSquare = false
        imageDrag = nil
    }

    /// Converts a box edited in the old box's local (unrotated) frame back to storage, so that with rotation
    /// around the new center the edited box lands where it was drawn.
    func place(_ local: CGRect, in old: CGRect, angle a: CGFloat) -> CGRect {
        let c = rotate(CGPoint(x: local.midX, y: local.midY), around: CGPoint(x: old.midX, y: old.midY), by: a)
        return CGRect(x: c.x - local.width / 2, y: c.y - local.height / 2, width: local.width, height: local.height)
    }

    private func setImageRect(_ i: Int, _ r: CGRect) {
        guard let (img, _) = imageParts(i) else { return }
        items[i].shape = .image(img, r)
    }

    // MARK: Single-image edits (menu / dialog / ⇧⌘X)

    func imageParts(_ i: Int?) -> (NSImage, CGRect)? {
        guard let i, i < items.count, items[i].editable, case .image(let img, let r) = items[i].shape else { return nil }
        return (img, r)
    }

    /// The image being edited: exactly one inserted image selected.
    var selectedImage: Int? {
        guard selected.count == 1, let i = selected.first, imageParts(i) != nil else { return nil }
        return i
    }

    var selectedImageRect: CGRect? { imageParts(selectedImage)?.1 }

    private func cgImage(_ img: NSImage) -> CGImage? {
        img.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    private func replaceImage(_ i: Int, _ cg: CGImage, rect: CGRect) {
        pushUndo()
        items[i].shape = .image(NSImage(cgImage: cg, size: rect.size), rect)
    }

    /// 90°/180° turns change the angle (so the box never grows); flips mirror the pixels.
    func transform(_ op: ImageOp) {
        finishText()
        guard let i = selectedImage, let (img, r) = imageParts(i) else { return }
        switch op {
        case .rotateRight, .rotateLeft, .rotate180:
            let turn: CGFloat = op == .rotateRight ? .pi / 2 : op == .rotateLeft ? -.pi / 2 : .pi
            pushUndo()
            items[i].angle = normalized(items[i].angle + turn)
        default:
            guard let cg = cgImage(img), let out = apply(op, to: cg, opaque: false) else { return }
            replaceImage(i, out, rect: r)
        }
    }

    /// Scale factors are relative to the image's current size; its top-left corner (own frame) stays put.
    func resizeSkew(sx: CGFloat, sy: CGFloat, skewX: CGFloat, skewY: CGFloat) {
        finishText()
        guard let i = selectedImage, let (img, r) = imageParts(i) else { return }
        let a = items[i].angle
        if skewX == 0 && skewY == 0 {
            // Plain resize: only the box changes, so repeated resizes don't lose quality.
            pushUndo()
            let local = CGRect(origin: r.origin, size: CGSize(width: r.width * sx, height: r.height * sy))
            items[i].shape = .image(img, place(local, in: r, angle: a))
            return
        }
        // Skew needs new pixels. Keep the image's own pixel density (`d` pixels per canvas point).
        guard let cg = cgImage(img) else { return }
        let d = max(CGFloat(cg.width) / r.width, CGFloat(cg.height) / r.height)
        let op = ImageOp.resizeSkew(sx: sx * r.width * d / CGFloat(cg.width),
                                    sy: sy * r.height * d / CGFloat(cg.height),
                                    skewX: skewX, skewY: skewY)
        guard let out = apply(op, to: cg, opaque: false) else { return }
        let local = CGRect(origin: r.origin, size: CGSize(width: CGFloat(out.width) / d, height: CGFloat(out.height) / d))
        replaceImage(i, out, rect: place(local, in: r, angle: a))
    }

    /// ⇧⌘X: keeps only the part of an image inside the drawn area (transparent outside a lasso).
    func crop() {
        finishText()
        guard let s = selection else { return }
        // The selected image, or else the topmost image the area touches.
        let target = selectedImage ?? items.indices.last { imageParts($0) != nil && items[$0].touches(s) }
        guard let i = target, let (img, r) = imageParts(i), let cg = cgImage(img) else { return }
        let a = items[i].angle
        let center = CGPoint(x: r.midX, y: r.midY)

        // Area in the image's own (unrotated) frame.
        var toLocal = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: -a).translatedBy(x: -center.x, y: -center.y)
        guard let areaLocal = s.path.cgPath.copy(using: &toLocal) else { return }
        let b = areaLocal.boundingBox.intersection(r)
        guard !b.isNull, b.width >= 1, b.height >= 1 else { return }

        // Local points (y-down) -> image pixels (y-up).
        let px = CGFloat(cg.width) / r.width, py = CGFloat(cg.height) / r.height
        var toPixels = CGAffineTransform(a: px, b: 0, c: 0, d: -py, tx: -r.minX * px, ty: r.maxY * py)
        let pb = b.applying(toPixels)
        guard let ctx = makeContext(Int(pb.width.rounded()), Int(pb.height.rounded()), opaque: false) else { return }
        ctx.translateBy(x: -pb.minX, y: -pb.minY)
        if let clip = areaLocal.copy(using: &toPixels) {
            ctx.addPath(clip)
            ctx.clip()
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        guard let out = ctx.makeImage() else { return }
        replaceImage(i, out, rect: place(b, in: r, angle: a))
        selected = [i]
        selection = nil
    }

    func openImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) else { return }
        insertImage(img, center: nil)
    }

    func insertImage(url: URL?, at p: CGPoint) -> Bool {
        guard let url, let img = NSImage(contentsOf: url) else { return false }
        insertImage(img, center: p)
        return true
    }

    /// Adds an image scaled to fit the visible area and selects it for editing. `center` is in world units.
    func insertImage(_ img: NSImage, center: CGPoint?) {
        guard img.size.width > 0, img.size.height > 0 else { return }
        finishText()
        let vp = viewport
        let s = min(1, vp.width * 0.9 / img.size.width, vp.height * 0.9 / img.size.height)
        let size = CGSize(width: img.size.width * s, height: img.size.height * s)
        let origin = center.map { CGPoint(x: $0.x - size.width / 2, y: $0.y - size.height / 2) }
            ?? CGPoint(x: vp.minX + 20 / zoom, y: vp.minY + 20 / zoom)
        commit(Item(shape: .image(img, CGRect(origin: origin, size: size)), color: .black, width: 0, editable: true))
        tool = .select
        selection = nil
        selected = [items.count - 1]
    }
}

// MARK: - Menu

private extension View {
    @ViewBuilder
    func shortcut(_ on: Bool, _ key: KeyEquivalent, _ mods: EventModifiers = .command) -> some View {
        if on { keyboardShortcut(key, modifiers: mods) } else { self }
    }
}

/// Shared by the toolbar menu and the menu bar ("이미지"); shortcuts only in the menu bar.
struct ImageMenuItems: View {
    @ObservedObject var m: Model
    let shortcuts: Bool

    var body: some View {
        Button("이미지 삽입…") { m.openImage() }.shortcut(shortcuts, "i", [.command, .shift])
        Divider()
        // Crop lives only in the menu bar, where it carries the ⇧⌘X shortcut.
        if shortcuts {
            Button("자르기 (선택 영역만 남기기)") { m.crop() }
                .keyboardShortcut("x", modifiers: [.command, .shift])
                .disabled(m.selection == nil)
        }
        Group {
            Button("크기 조정 및 기울이기…") { m.showResize = true }.shortcut(shortcuts, "r", [.command, .shift])
            Divider()
            Button("오른쪽으로 90° 회전") { m.transform(.rotateRight) }.shortcut(shortcuts, "]")
            Button("왼쪽으로 90° 회전") { m.transform(.rotateLeft) }.shortcut(shortcuts, "[")
            Button("180° 회전") { m.transform(.rotate180) }
            Button("좌우 대칭") { m.transform(.flipH) }.shortcut(shortcuts, "h", [.command, .shift])
            Button("상하 대칭") { m.transform(.flipV) }.shortcut(shortcuts, "v", [.command, .shift])
        }
        .disabled(m.selectedImageRect == nil)
    }
}

// MARK: - Resize / skew dialog

struct ResizeSheet: View {
    let base: CGSize
    let onApply: (CGFloat, CGFloat, CGFloat, CGFloat) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var byPercent = true
    @State private var wText = "100"
    @State private var hText = "100"
    @State private var keepRatio = true
    @State private var skewX = "0"
    @State private var skewY = "0"
    @FocusState private var focus: Field?

    enum Field { case w, h }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("크기 조정 및 기울이기").font(.headline)
                Text("선택한 이미지 · \(Int(base.width)) × \(Int(base.height)) px")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Picker("", selection: $byPercent) {
                Text("백분율").tag(true)
                Text("픽셀").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("가로")
                    TextField("", text: $wText).textFieldStyle(.roundedBorder).focused($focus, equals: .w)
                    Text(byPercent ? "%" : "px").foregroundStyle(.secondary)
                }
                GridRow {
                    Text("세로")
                    TextField("", text: $hText).textFieldStyle(.roundedBorder).focused($focus, equals: .h)
                    Text(byPercent ? "%" : "px").foregroundStyle(.secondary)
                }
            }
            Toggle("가로 세로 비율 유지", isOn: $keepRatio)

            Divider()

            Text("기울이기").font(.subheadline.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("가로")
                    TextField("", text: $skewX).textFieldStyle(.roundedBorder)
                    Text("도").foregroundStyle(.secondary)
                }
                GridRow {
                    Text("세로")
                    TextField("", text: $skewY).textFieldStyle(.roundedBorder)
                    Text("도").foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("확인", action: apply).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 300)
        .onChange(of: wText) { _, _ in sync(from: .w) }
        .onChange(of: hText) { _, _ in sync(from: .h) }
        .onChange(of: byPercent) { _, percent in
            guard let w = Double(wText), let h = Double(hText) else { return }
            wText = fmt(percent ? w / base.width * 100 : w * base.width / 100)
            hText = fmt(percent ? h / base.height * 100 : h * base.height / 100)
        }
    }

    /// Mirror the edited field into the other one when keeping the ratio.
    private func sync(from f: Field) {
        guard keepRatio, focus == f, let v = Double(f == .w ? wText : hText) else { return }
        let other: Double
        if byPercent {
            other = v
        } else {
            other = f == .w ? v * base.height / base.width : v * base.width / base.height
        }
        if f == .w { hText = fmt(other) } else { wText = fmt(other) }
    }

    private func fmt(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    private func apply() {
        guard let w = Double(wText), let h = Double(hText), w > 0, h > 0,
              let kx = Double(skewX), let ky = Double(skewY), abs(kx) < 90, abs(ky) < 90 else {
            NSSound.beep()
            return
        }
        let sx = byPercent ? w / 100 : w / base.width
        let sy = byPercent ? h / 100 : h / base.height
        onApply(sx, sy, kx, ky)
        dismiss()
    }
}
