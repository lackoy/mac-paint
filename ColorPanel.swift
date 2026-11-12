import SwiftUI
import AppKit

// MARK: - HSB color math

struct HSB: Equatable {
    var h: Double, s: Double, b: Double

    init(h: Double, s: Double, b: Double) {
        self.h = h; self.s = s; self.b = b
    }

    init(r: Double, g: Double, b bl: Double) {
        let mx = max(r, g, bl), mn = min(r, g, bl), d = mx - mn
        var hue = 0.0
        if d > 0 {
            if mx == r { hue = (g - bl) / d }
            else if mx == g { hue = 2 + (bl - r) / d }
            else { hue = 4 + (r - g) / d }
            hue /= 6
            if hue < 0 { hue += 1 }
        }
        self.init(h: hue, s: mx == 0 ? 0 : d / mx, b: mx)
    }

    init(_ color: Color) {
        let n = NSColor(color).usingColorSpace(.sRGB) ?? .black
        self.init(r: n.redComponent, g: n.greenComponent, b: n.blueComponent)
    }

    init?(hex: String) {
        let s = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        self.init(r: Double(v >> 16 & 0xFF) / 255, g: Double(v >> 8 & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }

    var rgb: (r: Double, g: Double, b: Double) {
        let hh = (h >= 1 ? 0 : h) * 6
        let i = Int(hh), f = hh - Double(i)
        let p = b * (1 - s), q = b * (1 - s * f), t = b * (1 - s * (1 - f))
        switch i {
        case 0: return (b, t, p)
        case 1: return (q, b, p)
        case 2: return (p, b, t)
        case 3: return (p, q, b)
        case 4: return (t, p, b)
        default: return (b, p, q)
        }
    }

    var rgb255: [Int] {
        let c = rgb
        return [c.r, c.g, c.b].map { Int(($0 * 255).rounded()) }
    }

    var hex: String { String(format: "%02X%02X%02X", rgb255[0], rgb255[1], rgb255[2]) }

    var color: Color {
        let c = rgb
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b)
    }
}

func hex(of color: Color) -> String { HSB(color).hex }

private func clamp01(_ v: CGFloat) -> Double { Double(min(max(v, 0), 1)) }

// 10 columns: grayscale row, then light → dark rows across 10 hues.
let basicColors: [HSB] = {
    var list = (0..<10).map { HSB(h: 0, s: 0, b: 1 - Double($0) / 9) }
    let hues = [0, 0.07, 0.14, 0.25, 0.36, 0.47, 0.55, 0.62, 0.75, 0.88]
    for (s, b) in [(0.2, 1.0), (0.5, 1.0), (1.0, 1.0), (1.0, 0.55)] {
        list += hues.map { HSB(h: $0, s: s, b: b) }
    }
    return list
}()

// MARK: - Pieces

struct Swatch: View {
    let color: Color
    let selected: Bool
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(color)
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: selected ? 2 : 0).padding(-3))
            .contentShape(Rectangle())
    }
}

/// Saturation (x) / brightness (y) square for the current hue.
struct SVPad: View {
    @Binding var hsb: HSB

    var body: some View {
        GeometryReader { g in
            ZStack {
                ZStack {
                    Color(hue: hsb.h, saturation: 1, brightness: 1)
                    LinearGradient(colors: [.white, .white.opacity(0)], startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))

                Circle()
                    .stroke(Color.white, lineWidth: 2)
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .frame(width: 12, height: 12)
                    .position(x: hsb.s * g.size.width, y: (1 - hsb.b) * g.size.height)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                hsb.s = clamp01(v.location.x / g.size.width)
                hsb.b = clamp01(1 - v.location.y / g.size.height)
            })
        }
    }
}

struct HueBar: View {
    @Binding var hue: Double

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .top) {
                LinearGradient(colors: (0...6).map { Color(hue: Double($0) / 6, saturation: 1, brightness: 1) },
                               startPoint: .top, endPoint: .bottom)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                RoundedRectangle(cornerRadius: 2)
                    .stroke(Color.white, lineWidth: 2)
                    .shadow(color: .black.opacity(0.5), radius: 1)
                    .frame(width: g.size.width + 4, height: 6)
                    .offset(y: hue * g.size.height - 3)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged {
                hue = min(clamp01($0.location.y / g.size.height), 0.999)
            })
        }
    }
}

// MARK: - Panel

struct ColorPanel: View {
    @Binding var color: Color
    @State private var hsb = HSB(h: 0, s: 0, b: 0)
    @State private var hexText = ""
    @AppStorage("customColors") private var customRaw = ""
    @State private var tapIndex = -1
    @State private var tapCount = 0
    @State private var tapTime = Date.distantPast

    private let slots = 10
    private let columns = Array(repeating: GridItem(.fixed(20), spacing: 6), count: 10)
    private var customs: [String] { customRaw.split(separator: ",").map(String.init) }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                header("기본 색상")
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(basicColors.indices, id: \.self) { i in
                        let c = basicColors[i]
                        Swatch(color: c.color, selected: c.hex == hsb.hex).onTapGesture { hsb = c }
                    }
                }
                header("사용자 색상").padding(.top, 8)
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(0..<slots, id: \.self) { i in
                        if i < customs.count, let c = HSB(hex: customs[i]) {
                            Swatch(color: c.color, selected: c.hex == hsb.hex)
                                .onTapGesture { tapCustom(at: i, c) }
                                .contextMenu { Button("삭제") { removeCustom(at: i) } }
                        } else {
                            RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3]))
                                .frame(width: 20, height: 20)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    SVPad(hsb: $hsb).frame(width: 160, height: 160)
                    HueBar(hue: $hsb.h).frame(width: 14, height: 160)
                }
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hsb.color)
                        .frame(width: 28, height: 22)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15)))
                    Text("#").foregroundStyle(.secondary)
                    TextField("", text: $hexText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit {
                            if let c = HSB(hex: hexText) { hsb = c } else { hexText = hsb.hex }
                        }
                }
                HStack(spacing: 6) {
                    channel("R", 0)
                    channel("G", 1)
                    channel("B", 2)
                }
                Button(action: addCustom) {
                    Label("사용자 색상에 추가", systemImage: "plus").frame(maxWidth: .infinity)
                }
            }
            .frame(width: 184)
        }
        .padding(16)
        .onAppear {
            hsb = HSB(color)
            hexText = hsb.hex
        }
        .onChange(of: hsb) { _, v in
            color = v.color
            hexText = v.hex
        }
    }

    private func header(_ s: String) -> some View {
        Text(s).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    }

    private func channel(_ name: String, _ i: Int) -> some View {
        let binding = Binding<Int>(
            get: { hsb.rgb255[i] },
            set: { v in
                var a = hsb.rgb255
                a[i] = min(max(v, 0), 255)
                hsb = HSB(r: Double(a[0]) / 255, g: Double(a[1]) / 255, b: Double(a[2]) / 255)
            }
        )
        return HStack(spacing: 3) {
            Text(name).font(.caption).foregroundStyle(.secondary)
            TextField("", value: binding, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
        }
    }

    private func addCustom() {
        var list = customs.filter { $0 != hsb.hex }
        list.insert(hsb.hex, at: 0)
        customRaw = list.prefix(slots).joined(separator: ",")
    }

    /// Single click selects; three quick clicks on the same slot remove it.
    private func tapCustom(at i: Int, _ c: HSB) {
        let now = Date()
        if i == tapIndex && now.timeIntervalSince(tapTime) < NSEvent.doubleClickInterval {
            tapCount += 1
        } else {
            tapCount = 1
        }
        tapIndex = i
        tapTime = now
        if tapCount >= 3 {
            removeCustom(at: i)
            tapIndex = -1
        } else {
            hsb = c
        }
    }

    private func removeCustom(at i: Int) {
        var list = customs
        list.remove(at: i)
        customRaw = list.joined(separator: ",")
    }
}
