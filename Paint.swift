import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Model

enum Tool: CaseIterable {
    case select, lasso, pen, line, arrow, rect, ellipse, text, eraser, bucket, picker

    var isSelection: Bool { self == .select || self == .lasso }

    var icon: String {
        switch self {
        case .select: "rectangle.dashed"
        case .lasso: "lasso"
        case .bucket: "drop.fill"
        case .picker: "eyedropper"
        case .pen: "pencil.tip"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .rect: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        case .eraser: "eraser"
        }
    }

    var name: String {
        switch self {
        case .select: "사각형 선택"
        case .lasso: "자유형 선택"
        case .pen: "펜"
        case .line: "직선"
        case .arrow: "화살표"
        case .rect: "사각형"
        case .ellipse: "원"
        case .text: "텍스트"
        case .eraser: "지우개"
        case .bucket: "페인트 통"
        case .picker: "스포이드"
        }
    }
}

enum Shape {
    case stroke([CGPoint])
    case line(CGPoint, CGPoint)
    case arrow(CGPoint, CGPoint)
    case rect(CGPoint, CGPoint)
    case ellipse(CGPoint, CGPoint)
    case text(String, CGPoint)
    case image(NSImage, CGRect)
}

struct Item {
    var shape: Shape
    var color: Color
    var width: CGFloat
    /// Inserted/pasted pictures can be selected and edited; bucket-fill layers cannot.
    var editable = false
    /// Live rotation (radians, clockwise) while dragging a rotate handle; baked into the pixels on release.
    var angle: CGFloat = 0
}

func rectFrom(_ a: CGPoint, _ b: CGPoint) -> CGRect {
    CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
}

func fontSize(_ width: CGFloat) -> CGFloat { 12 + width * 2 }

func draw(_ item: Item, in ctx: GraphicsContext) {
    let style = StrokeStyle(lineWidth: item.width, lineCap: .round, lineJoin: .round)
    var path = Path()
    switch item.shape {
    case .stroke(let pts):
        path.addLines(pts)
    case .line(let a, let b):
        path.move(to: a)
        path.addLine(to: b)
    case .arrow(let a, let b):
        path.move(to: a)
        path.addLine(to: b)
        let angle = atan2(b.y - a.y, b.x - a.x)
        let len = max(12, item.width * 4)
        for d in [CGFloat.pi * 0.8, -CGFloat.pi * 0.8] {
            path.move(to: b)
            path.addLine(to: CGPoint(x: b.x + len * cos(angle + d), y: b.y + len * sin(angle + d)))
        }
    case .rect(let a, let b):
        path.addRect(rectFrom(a, b))
    case .ellipse(let a, let b):
        path.addEllipse(in: rectFrom(a, b))
    case .text(let s, let pt):
        let text = Text(s).font(.system(size: fontSize(item.width))).foregroundColor(item.color)
        ctx.draw(text, at: pt, anchor: .topLeading)
        return
    case .image(let img, let r):
        var c = ctx
        if item.angle != 0 {
            c.translateBy(x: r.midX, y: r.midY)
            c.rotate(by: .radians(item.angle))
            c.translateBy(x: -r.midX, y: -r.midY)
        }
        c.draw(Image(nsImage: img), in: r)
        return
    }
    ctx.stroke(path, with: .color(item.color), style: style)
}

@MainActor
final class Model: ObservableObject {
    @Published var items: [Item] = []
    @Published var current: Item?
    @Published var tool: Tool = .pen {
        didSet {
            if tool != .text { finishText() }
            if tool == .picker && oldValue != .picker { toolBeforePicker = oldValue }
            if !tool.isSelection {
                selection = nil
                selected = []
            }
        }
    }
    @Published var selection: Selection?
    @Published var showResize = false
    /// Indices in `items` currently selected (drawings and inserted images).
    @Published var selected: Set<Int> = []
    var selecting = false
    /// True between the first onChanged and onEnded of one mouse drag.
    private var dragActive = false
    /// Set when the current drag moves or resizes the selected image instead of drawing.
    @Published var imageDrag: ImageDrag?
    /// While corner-resizing: the size snapped to a square (a diagonal guide is shown).
    @Published var snappedSquare = false
    private var toolBeforePicker: Tool = .pen
    @Published var color: Color = .black
    @Published var width: CGFloat = 3
    @Published var textPos: CGPoint?
    @Published var textValue = ""

    private var undoStack: [[Item]] = []
    private var redoStack: [[Item]] = []
    /// On-screen size of the canvas view (the drawing itself is unbounded; see Viewport.swift).
    var canvasSize = CGSize(width: 800, height: 600)
    /// Canvas view frame in window coordinates (for mapping scroll / pinch events).
    var canvasFrame = CGRect.zero
    @Published var zoom: CGFloat = 1
    @Published var pan = CGSize.zero

    var isEditingText: Bool { textPos != nil }

    func pushUndo(_ snapshot: [Item]? = nil) {
        undoStack.append(snapshot ?? items)
        redoStack.removeAll()
    }

    func commit(_ item: Item) {
        pushUndo()
        items.append(item)
    }

    func undo() {
        finishText()
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(items)
        items = prev
        clampSelectedImage()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(items)
        items = next
        clampSelectedImage()
    }

    func clear() {
        finishText()
        guard !items.isEmpty else { return }
        pushUndo()
        items = []
        selected = []
        selection = nil
    }

    func finishText() {
        if let pos = textPos, !textValue.trimmingCharacters(in: .whitespaces).isEmpty {
            commit(Item(shape: .text(textValue, pos), color: color, width: width))
        }
        textPos = nil
        textValue = ""
    }

    func dragChanged(start: CGPoint, loc: CGPoint) {
        if !dragActive {
            dragActive = true
            imageDrag = beginImageDrag(at: start)
        }
        if imageDrag != nil {
            continueImageDrag(start: start, loc: loc)
            return
        }
        switch tool {
        case .text, .bucket, .picker:
            return
        case .select:
            selection = .rect(rectFrom(start, loc))
            selecting = true
        case .lasso:
            if selecting, case .lasso(var pts)? = selection {
                pts.append(loc)
                selection = .lasso(pts)
            } else {
                selection = .lasso([start, loc])
            }
            selecting = true
        case .pen, .eraser:
            if case .stroke(var pts)? = current?.shape {
                pts.append(loc)
                current?.shape = .stroke(pts)
            } else {
                let eraser = tool == .eraser
                current = Item(shape: .stroke([start, loc]),
                               color: eraser ? .white : color,
                               width: eraser ? max(width * 4, 12) : width)
            }
        case .line: current = Item(shape: .line(start, loc), color: color, width: width)
        case .arrow: current = Item(shape: .arrow(start, loc), color: color, width: width)
        case .rect: current = Item(shape: .rect(start, loc), color: color, width: width)
        case .ellipse: current = Item(shape: .ellipse(start, loc), color: color, width: width)
        }
    }

    func dragEnded(loc: CGPoint) {
        dragActive = false
        if imageDrag != nil {
            endImageDrag()
            return
        }
        if tool.isSelection {
            selecting = false
            guard let s = selection else { return }
            let b = s.path.boundingRect
            if b.width < 3 || b.height < 3 {
                // A plain click clears the area and selects the item under the cursor, if any.
                selection = nil
                selected = itemIndex(at: loc).map { [$0] } ?? []
            } else {
                // Everything the area touches gets selected; the area stays so ⇧⌘X can crop an image to it.
                selected = indices(touching: s)
            }
            return
        }
        if tool == .text {
            finishText()
            textPos = loc
            return
        }
        if tool == .picker {
            pickColor(at: loc)
            return
        }
        if tool == .bucket {
            fill(at: loc)
            return
        }
        if let c = current { commit(c) }
        current = nil
    }

    // MARK: Raster tools

    /// Renders world rect `rect` into an RGBA buffer (row 0 = top), `scale` pixels per world unit.
    private func rasterize(_ rect: CGRect, scale: CGFloat) -> (buf: [UInt8], w: Int, h: Int)? {
        let view = CanvasContent(items: items, current: nil, origin: rect.origin)
            .frame(width: rect.width, height: rect.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        guard let cg = renderer.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (buf, w, h) : nil
    }

    private func pickColor(at p: CGPoint) {
        let vp = viewport
        guard let (buf, w, h) = rasterize(vp, scale: zoom) else { return }
        let x = Int((p.x - vp.minX) * zoom), y = Int((p.y - vp.minY) * zoom)
        guard x >= 0, y >= 0, x < w, y < h else { return }
        let i = (y * w + x) * 4
        color = Color(.sRGB, red: Double(buf[i]) / 255, green: Double(buf[i + 1]) / 255, blue: Double(buf[i + 2]) / 255)
        tool = toolBeforePicker
    }

    /// Flood-fills the region under `p` and adds the result as an image layer (undoable).
    /// The canvas is unbounded, so the fill is limited to the visible area.
    private func fill(at p: CGPoint) {
        let vp = viewport
        let scale = zoom * (NSScreen.main?.backingScaleFactor ?? 2)
        guard let (buf, w, h) = rasterize(vp, scale: scale) else { return }
        let sx = Int((p.x - vp.minX) * scale), sy = Int((p.y - vp.minY) * scale)
        guard sx >= 0, sy >= 0, sx < w, sy < h else { return }

        let fillRGB = HSB(color).rgb255.map(UInt8.init)
        let s = (sy * w + sx) * 4
        let target = (buf[s], buf[s + 1], buf[s + 2])
        if target == (fillRGB[0], fillRGB[1], fillRGB[2]) { return }

        let tol = 48
        func matches(_ i: Int) -> Bool {
            let o = i * 4
            return abs(Int(buf[o]) - Int(target.0)) <= tol
                && abs(Int(buf[o + 1]) - Int(target.1)) <= tol
                && abs(Int(buf[o + 2]) - Int(target.2)) <= tol
        }

        var mask = [Bool](repeating: false, count: w * h)
        var stack = [sy * w + sx]
        while let i = stack.popLast() {
            if mask[i] || !matches(i) { continue }
            mask[i] = true
            let x = i % w
            if x > 0 { stack.append(i - 1) }
            if x < w - 1 { stack.append(i + 1) }
            if i >= w { stack.append(i - w) }
            if i < w * (h - 1) { stack.append(i + w) }
        }

        // Grow by 1px so the fill tucks under anti-aliased edges instead of leaving a halo.
        var out = [UInt8](repeating: 0, count: w * h * 4)
        for i in 0..<(w * h) {
            let x = i % w
            let hit = mask[i]
                || (x > 0 && mask[i - 1]) || (x < w - 1 && mask[i + 1])
                || (i >= w && mask[i - w]) || (i < w * (h - 1) && mask[i + w])
            if hit {
                let o = i * 4
                out[o] = fillRGB[0]; out[o + 1] = fillRGB[1]; out[o + 2] = fillRGB[2]; out[o + 3] = 255
            }
        }

        let cg: CGImage? = out.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        guard let cg else { return }
        let img = NSImage(cgImage: cg, size: vp.size)
        commit(Item(shape: .image(img, vp), color: color, width: 0))
    }

    // MARK: Export / clipboard

    /// Exports exactly what is visible on screen (current zoom and scroll position).
    func render() -> NSImage? {
        let view = CanvasContent(items: items, current: nil, origin: viewport.origin, scale: zoom)
            .frame(width: canvasSize.width, height: canvasSize.height)
        let renderer = ImageRenderer(content: view)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        return renderer.nsImage
    }

    func copyImage() {
        finishText()
        guard let img = render() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([img])
    }

    func pasteImage() {
        guard let img = NSImage(pasteboard: .general) else { return }
        insertImage(img, center: nil)
    }

    func save() {
        finishText()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "그림.png"
        guard panel.runModal() == .OK, let url = panel.url,
              let tiff = render()?.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url)
    }
}

// MARK: - Views

struct CanvasContent: View {
    let items: [Item]
    let current: Item?
    /// World point shown at the view's top-left, and view points per world unit.
    var origin: CGPoint = .zero
    var scale: CGFloat = 1

    var body: some View {
        Canvas { ctx, _ in
            var c = ctx
            c.scaleBy(x: scale, y: scale)
            c.translateBy(x: -origin.x, y: -origin.y)
            for item in items { draw(item, in: c) }
            if let cur = current { draw(cur, in: c) }
        }
        .background(Color.white)
    }
}

struct ContentView: View {
    @ObservedObject var m: Model
    @FocusState private var textFocused: Bool
    @State private var showColors = false

    private let palette: [Color] = [.black, .gray, .red, .orange, .yellow, .green, .blue, .purple]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            GeometryReader { geo in
                canvas
                    .overlay(alignment: .bottomTrailing) { ZoomControl(m: m) }
                    .onAppear {
                        m.canvasSize = geo.size
                        m.canvasFrame = geo.frame(in: .global)
                    }
                    .onChange(of: geo.frame(in: .global)) { _, f in
                        m.canvasSize = f.size
                        m.canvasFrame = f
                    }
            }
        }
        .frame(minWidth: 1000, minHeight: 500)
        .sheet(isPresented: $m.showResize) {
            if let r = m.selectedImageRect {
                ResizeSheet(base: r.size, onApply: m.resizeSkew)
            }
        }
    }

    private var canvas: some View {
                ZStack(alignment: .topLeading) {
                    CanvasContent(items: m.items, current: m.current, origin: m.toWorld(.zero), scale: m.zoom)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { m.dragChanged(start: m.toWorld($0.startLocation), loc: m.toWorld($0.location)) }
                                .onEnded { m.dragEnded(loc: m.toWorld($0.location)) }
                        )
                    if let i = m.selectedImage, let r = m.selectedImageRect {
                        imageDecorations(i, r)
                    } else if let wb = m.selectionBounds {
                        let b = m.toScreen(wb)
                        Rectangle()
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
                            .frame(width: b.width + 6, height: b.height + 6)
                            .offset(x: b.minX - 3, y: b.minY - 3)
                            .allowsHitTesting(false)
                    }
                    if let sel = m.selection {
                        ZStack {
                            let path = sel.path.applying(m.viewTransform)
                            path.stroke(Color.white, lineWidth: 1)
                            path.stroke(Color.black, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        }
                        .allowsHitTesting(false)
                    }
                    if let p = m.textPos {
                        let sp = m.toScreen(p)
                        TextField("", text: $m.textValue)
                            .textFieldStyle(.plain)
                            .font(.system(size: fontSize(m.width) * m.zoom))
                            .foregroundColor(m.color)
                            .frame(width: 320, alignment: .leading)
                            .overlay(Rectangle().stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [4])))
                            .focused($textFocused)
                            .onSubmit { m.finishText() }
                            .onAppear { textFocused = true }
                            .id("\(p.x),\(p.y)")
                            .offset(x: sp.x, y: sp.y)
                    }
                }
                .clipped()
                .dropDestination(for: URL.self) { urls, loc in
                    m.insertImage(url: urls.first, at: m.toWorld(loc))
                }
                .onAppear {
                    installBackspaceMonitor(m)
                    installViewMonitor(m)
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): cursor(for: m.hoverZone(at: m.toWorld(p))).set()
                    case .ended: NSCursor.arrow.set()
                    }
                }
    }

    /// Single selected image: rotated dashed outline, corner handles, square-snap diagonal, live size/angle label.
    @ViewBuilder
    private func imageDecorations(_ i: Int, _ r: CGRect) -> some View {
        let rotating: Bool = { if case .rotate = m.imageDrag { return true } else { return false } }()
        let resizingCorner: Int? = { if case .resize(_, _, let c, _) = m.imageDrag { return c } else { return nil } }()
        let angle = m.items[i].angle
        let bounds = m.toScreen(m.items[i].bounds)
        let sr = m.toScreen(r)  // same box on screen (uniform zoom keeps the rotation)

        Rectangle()
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [6, 3]))
            .frame(width: sr.width + 4, height: sr.height + 4)
            .rotationEffect(.radians(angle))
            .offset(x: sr.minX - 2, y: sr.minY - 2)
            .allowsHitTesting(false)

        if !rotating {
            ForEach(0..<4, id: \.self) { c in
                let p = worldCorner(sr, angle, c)
                Rectangle()
                    .fill(Color.white)
                    .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1.5))
                    .frame(width: 9, height: 9)
                    .offset(x: p.x - 4.5, y: p.y - 4.5)
                    .allowsHitTesting(false)
            }
        }

        if let c = resizingCorner, m.snappedSquare {
            Path { p in
                p.move(to: worldCorner(sr, angle, 3 - c))
                p.addLine(to: worldCorner(sr, angle, c))
            }
            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            .allowsHitTesting(false)
        }

        if rotating || resizingCorner != nil {
            Text(rotating
                 ? "\(Int((angle * 180 / .pi).rounded()))°"
                 : "\(Int(r.width.rounded())) × \(Int(r.height.rounded()))\(m.snappedSquare ? "  정사각형" : "")")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.black.opacity(0.75)))
                .fixedSize()
                .position(x: bounds.midX, y: bounds.maxY + 18)
                .allowsHitTesting(false)
        }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Menu {
                ImageMenuItems(m: m, shortcuts: false)
            } label: {
                Image(systemName: "photo")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("이미지")

            Divider().frame(height: 24)

            HStack(spacing: 2) {
                ForEach(Tool.allCases, id: \.self) { t in
                Button { m.tool = t } label: {
                    Image(systemName: t.icon)
                        .frame(width: 28, height: 28)
                        .background(m.tool == t ? Color.accentColor.opacity(0.25) : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(t.name)
                }
            }

            Divider().frame(height: 24)

            Button { showColors.toggle() } label: {
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(m.color)
                        .frame(width: 26, height: 20)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.2)))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("색상 편집")
            .popover(isPresented: $showColors, arrowEdge: .bottom) {
                ColorPanel(color: $m.color)
            }

            ForEach(palette, id: \.self) { c in
                let selected = hex(of: m.color) == hex(of: c)
                Circle()
                    .fill(c)
                    .frame(width: 18, height: 18)
                    .overlay(Circle().stroke(selected ? Color.accentColor : Color.secondary.opacity(0.4),
                                             lineWidth: selected ? 3 : 1))
                    .onTapGesture { m.color = c }
            }

            Divider().frame(height: 24)

            Image(systemName: "lineweight")
            Slider(value: $m.width, in: 1...20).frame(width: 100)
            Text("\(Int(m.width))").monospacedDigit().frame(width: 22)

            Spacer()

            Button { m.undo() } label: { Image(systemName: "arrow.uturn.backward") }.help("실행 취소 (⌘Z)")
            Button { m.redo() } label: { Image(systemName: "arrow.uturn.forward") }.help("다시 실행 (⇧⌘Z)")
            Button { m.clear() } label: { Image(systemName: "trash") }.help("모두 지우기 (⌘⌫)")
            Button { m.copyImage() } label: { Image(systemName: "doc.on.doc") }.help("이미지 복사 (⌘C)")
        }
        .padding(8)
    }
}

// MARK: - App

private var backspaceMonitor: Any?

/// Backspace (the Mac "delete" key, keyCode 51) removes the selection, unless a text field is being edited
/// or a sheet/popover window has the keyboard.
@MainActor
func installBackspaceMonitor(_ m: Model) {
    guard backspaceMonitor == nil else { return }
    backspaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
        guard event.keyCode == 51,
              event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
              let window = event.window, window == NSApp.mainWindow, window.attachedSheet == nil,
              !(window.firstResponder is NSText) else { return event }
        return m.deleteSelected() ? nil : event
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct PaintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var m = Model()

    private func send(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }

    var body: some Scene {
        Window("그림판", id: "main") {
            ContentView(m: m)
        }
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("PNG로 저장…") { m.save() }.keyboardShortcut("s")
            }
            CommandGroup(replacing: .undoRedo) {
                Button("실행 취소") { m.isEditingText ? send(Selector(("undo:"))) : m.undo() }
                    .keyboardShortcut("z")
                Button("다시 실행") { m.isEditingText ? send(Selector(("redo:"))) : m.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            // While typing text, clipboard shortcuts go to the text field; otherwise they act on the canvas.
            CommandGroup(replacing: .pasteboard) {
                Button("잘라내기") { if m.isEditingText { send(#selector(NSText.cut(_:))) } }
                    .keyboardShortcut("x")
                Button("복사") { m.isEditingText ? send(#selector(NSText.copy(_:))) : m.copyImage() }
                    .keyboardShortcut("c")
                Button("붙여넣기") { m.isEditingText ? send(#selector(NSText.paste(_:))) : m.pasteImage() }
                    .keyboardShortcut("v")
                Button("전체 선택") { if m.isEditingText { send(#selector(NSText.selectAll(_:))) } }
                    .keyboardShortcut("a")
                Divider()
                Button("모두 지우기") { m.clear() }.keyboardShortcut(.delete)
            }
            CommandGroup(after: .toolbar) {
                Button("확대") { m.zoomIn() }.keyboardShortcut("=")
                Button("축소") { m.zoomOut() }.keyboardShortcut("-")
                Button("실제 크기 (100%)") { m.resetZoom() }.keyboardShortcut("0")
                Divider()
            }
            CommandMenu("이미지") {
                ImageMenuItems(m: m, shortcuts: true)
            }
        }
    }
}
