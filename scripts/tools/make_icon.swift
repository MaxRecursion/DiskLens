// Renders the DiskLens app icon (1024×1024, macOS icon grid) and writes an .iconset + PNG.
// Usage: swiftc -O make_icon.swift -o make_icon && ./make_icon <output-dir>
import SwiftUI
import AppKit

struct Tile: Identifiable { let id: Int; let rect: CGRect; let color: Color }

/// A fixed, hand-balanced treemap so the icon is deterministic.
let palette: [Color] = [
    Color(red: 0.30, green: 0.56, blue: 0.98),   // applications blue
    Color(red: 0.62, green: 0.42, blue: 0.96),   // developer purple
    Color(red: 0.20, green: 0.78, blue: 0.62),   // caches teal
    Color(red: 0.98, green: 0.80, blue: 0.25),   // AI yellow
    Color(red: 0.95, green: 0.38, blue: 0.55),   // SDK pink
    Color(red: 0.96, green: 0.62, blue: 0.20),   // documents orange
    Color(red: 0.38, green: 0.80, blue: 0.95),   // downloads cyan
]

func tiles(in r: CGRect) -> [Tile] {
    // Proportions roughly follow a real squarified layout (big → small).
    let g: CGFloat = 14
    let w = r.width, h = r.height
    var out: [Tile] = []
    func add(_ x: CGFloat, _ y: CGFloat, _ ww: CGFloat, _ hh: CGFloat, _ c: Int) {
        out.append(Tile(id: out.count, rect: CGRect(x: r.minX + x * w + g / 2, y: r.minY + y * h + g / 2,
                                                    width: ww * w - g, height: hh * h - g), color: palette[c]))
    }
    add(0.00, 0.00, 0.56, 0.58, 0)
    add(0.56, 0.00, 0.44, 0.34, 1)
    add(0.56, 0.34, 0.24, 0.24, 2)
    add(0.80, 0.34, 0.20, 0.24, 5)
    add(0.00, 0.58, 0.34, 0.42, 4)
    add(0.34, 0.58, 0.22, 0.42, 3)
    add(0.56, 0.58, 0.26, 0.24, 6)
    add(0.82, 0.58, 0.18, 0.24, 2)
    add(0.56, 0.82, 0.16, 0.18, 1)
    add(0.72, 0.82, 0.14, 0.18, 0)
    add(0.86, 0.82, 0.14, 0.18, 5)
    return out
}

struct IconView: View {
    let size: CGFloat = 1024
    var body: some View {
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)          // macOS icon grid
        let inner = body.insetBy(dx: 88, dy: 88)
        ZStack {
            Color.clear
            // Squircle body with depth.
            // Exactly the system squircle, nothing outside it (macOS 26+ plates icons that overflow).
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.13, green: 0.15, blue: 0.27), Color(red: 0.05, green: 0.06, blue: 0.11)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: body.width, height: body.height)
            RoundedRectangle(cornerRadius: 185, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.22), .white.opacity(0.02)], startPoint: .top, endPoint: .bottom), lineWidth: 3)
                .frame(width: body.width, height: body.height)
            // Treemap, clipped to the body so nothing overflows the squircle.
            ForEach(tiles(in: inner)) { t in
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(LinearGradient(colors: [t.color.opacity(0.95), t.color.opacity(0.70)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: t.rect.width, height: t.rect.height)
                    .position(x: t.rect.midX, y: t.rect.midY)
            }
            // Magnifying lens over the lower-right of the treemap.
            let c = CGPoint(x: 585, y: 575)
            let rLens: CGFloat = 158
            // Handle
            Capsule()
                .fill(LinearGradient(colors: [Color(white: 0.96), Color(white: 0.70)], startPoint: .top, endPoint: .bottom))
                .frame(width: 64, height: 190)
                .rotationEffect(.degrees(-45))
                .position(x: c.x + rLens * 0.95 + 40, y: c.y + rLens * 0.95 + 40)
                .shadow(color: .black.opacity(0.45), radius: 10, x: 0, y: 8)
            // Glass: darkened, slightly magnified view of the tiles.
            Circle()
                .fill(RadialGradient(colors: [.white.opacity(0.28), .white.opacity(0.06)], center: UnitPoint(x: 0.35, y: 0.3),
                                     startRadius: 10, endRadius: rLens * 1.2))
                .background(Circle().fill(Color.black.opacity(0.25)))
                .frame(width: rLens * 2, height: rLens * 2)
                .position(c)
            // Lens rim
            Circle()
                .strokeBorder(LinearGradient(colors: [Color(white: 1.0), Color(white: 0.72)], startPoint: .topLeading, endPoint: .bottomTrailing),
                              lineWidth: 30)
                .frame(width: rLens * 2 + 30, height: rLens * 2 + 30)
                .position(c)
                .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 10)
            // Highlight arc
            Circle()
                .trim(from: 0.55, to: 0.78)
                .stroke(Color.white.opacity(0.75), style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .frame(width: rLens * 1.5, height: rLens * 1.5)
                .position(c)
        }
        .frame(width: size, height: size)
        // Nothing may fall outside the standard macOS squircle.
        .mask(RoundedRectangle(cornerRadius: 185, style: .continuous).frame(width: 824, height: 824))
    }
}

/// Menu-bar template icon (18 pt): a 2×2 treemap outline under a lens, black on transparent.
/// macOS tints template images for light/dark menu bars automatically.
struct MenuBarIconView: View {
    var body: some View {
        ZStack {
            Canvas { ctx, _ in
                let tiles = [CGRect(x: 1, y: 2, width: 8, height: 9), CGRect(x: 10, y: 2, width: 7, height: 5),
                             CGRect(x: 1, y: 12, width: 5, height: 5), CGRect(x: 7, y: 12, width: 4, height: 5)]
                for t in tiles { ctx.fill(Path(roundedRect: t, cornerRadius: 1.4), with: .color(.black)) }
                // Lens: clear the area under it, then draw the ring and handle.
                let lens = CGRect(x: 9.2, y: 8.2, width: 6.6, height: 6.6)
                ctx.blendMode = .clear
                ctx.fill(Path(ellipseIn: lens.insetBy(dx: -1.4, dy: -1.4)), with: .color(.black))
                ctx.blendMode = .normal
                ctx.stroke(Path(ellipseIn: lens), with: .color(.black), lineWidth: 1.6)
                var handle = Path()
                handle.move(to: CGPoint(x: 14.8, y: 13.8)); handle.addLine(to: CGPoint(x: 17.2, y: 16.2))
                ctx.stroke(handle, with: .color(.black), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        }
        .frame(width: 18, height: 18)
    }
}

@MainActor
func renderMenuBar(scale: CGFloat) -> Data? {
    let r = ImageRenderer(content: MenuBarIconView())
    r.scale = scale
    guard let cg = r.cgImage else { return nil }
    return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
}

@MainActor
func render(_ px: Int) -> NSBitmapImageRep? {
    let r = ImageRenderer(content: IconView())
    r.scale = CGFloat(px) / 1024
    guard let cg = r.cgImage else { return nil }
    return NSBitmapImageRep(cgImage: cg)
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconset = URL(fileURLWithPath: out).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                              ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
MainActor.assumeIsolated {
    for (name, px) in sizes {
        guard let rep = render(px), let png = rep.representation(using: .png, properties: [:]) else { fatalError("render failed") }
        try! png.write(to: iconset.appendingPathComponent("icon_\(name).png"))
    }
    if let rep = render(1024), let png = rep.representation(using: .png, properties: [:]) {
        try! png.write(to: URL(fileURLWithPath: out).appendingPathComponent("AppIcon-1024.png"))
    }
}
MainActor.assumeIsolated {
    let base = URL(fileURLWithPath: out)
    try! renderMenuBar(scale: 1)!.write(to: base.appendingPathComponent("MenuBarIcon.png"))
    try! renderMenuBar(scale: 2)!.write(to: base.appendingPathComponent("MenuBarIcon@2x.png"))
}
print("wrote \(iconset.path) and MenuBarIcon(.png/@2x.png)")
