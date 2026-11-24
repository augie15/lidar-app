import SwiftUI
import AppKit
import simd

// Renders App Store creative assets (product page header, search result) with the real Tilda mark.
// Build and run from the repo root:
//   swiftc -O -o /tmp/render-creative scripts/render-creative.swift Tilda/Theme/TildaMark.swift
//   /tmp/render-creative docs/app-store/screenshots docs/app-store/creative [--guides]
// --guides draws Apple's art safe area in red, for checking only (do not upload those files).
// Specs (App Store Connect creative assets): header 3840x1646 PNG, safe area 1646x661 at (1097, 493);
// search result 3840x2560, safe area 2168x1030 at (836, 765). No alpha.

let bg = Color(red: 0x0E/255, green: 0x14/255, blue: 0x12/255)
let tile = Color(red: 0x0B/255, green: 0x1F/255, blue: 0x1A/255)
let featured = Color(red: 0x16/255, green: 0x3A/255, blue: 0x30/255)
let teal = Color(red: 0x5D/255, green: 0xCA/255, blue: 0xA5/255)
let tealText = Color(red: 0x9F/255, green: 0xE1/255, blue: 0xCB/255)
let secondary = Color(red: 0xB4/255, green: 0xB2/255, blue: 0xA9/255)

/// Deterministic pseudo-random numbers so renders are repeatable.
struct RNG { var s: UInt64; mutating func next() -> CGFloat { s = s &* 6364136223846793005 &+ 1442695040888963407; return CGFloat((s >> 33) % 1_000_000) / 1_000_000 } }

/// A LiDAR-style point cloud of an L-shaped room seen in perspective, drawn as teal dots that fade with depth.
struct PointRoom: View {
    var focus: CGPoint        // screen point the room is centred on (fraction of canvas)
    var scale: CGFloat        // room size relative to canvas height
    var density: Int
    var body: some View {
        Canvas { ctx, size in
            var rng = RNG(s: 42)
            // Room in metres: floor 8 x 6 with walls 2.6 high, camera above and in front.
            func project(_ p: SIMD3<Double>) -> (CGPoint, Double)? {
                // camera at (4, 5.5, 13) looking at (4, 0.8, 3)
                let cam = SIMD3<Double>(4, 5.6, 12.5), target = SIMD3<Double>(4, 0.6, 3)
                let f = simd_normalize(target - cam)
                let r = simd_normalize(simd_cross(f, SIMD3(0, 1, 0)))
                let u = simd_cross(r, f)
                let d = p - cam
                let z = simd_dot(d, f); guard z > 0.5 else { return nil }
                let x = simd_dot(d, r) / z, y = simd_dot(d, u) / z
                let k = Double(size.height * scale)
                return (CGPoint(x: Double(size.width * focus.x) + x * k, y: Double(size.height * focus.y) - y * k), z)
            }
            func dot(_ p: SIMD3<Double>, _ a: Double) {
                guard let (pt, z) = project(p) else { return }
                let rad = max(1.2, 7.5 / z) * Double(size.height) / 1646
                let fade = max(0.05, min(1, 1.6 - z / 14))
                ctx.fill(Path(ellipseIn: CGRect(x: pt.x - rad, y: pt.y - rad, width: rad * 2, height: rad * 2)),
                         with: .color(teal.opacity(min(1, a * fade * 1.7))))
            }
            let H = 2.6
            // Floor (L shape): main 0..8 x 0..6, minus 5..8 x 0..2.5 notch.
            for _ in 0..<density {
                let x = Double(rng.next()) * 8, z = Double(rng.next()) * 6
                if x > 5 && z < 2.5 { continue }
                dot(SIMD3(x, 0, z), 0.20)
            }
            // Walls as vertical sample lines (denser, brighter).
            let walls: [(SIMD2<Double>, SIMD2<Double>)] = [
                ([0, 0], [5, 0]), ([5, 0], [5, 2.5]), ([5, 2.5], [8, 2.5]), ([8, 2.5], [8, 6]), ([0, 0], [0, 6]),
            ]
            for (a, b) in walls {
                let len = simd_distance(a, b)
                for _ in 0..<Int(len * Double(density) / 40) {
                    let t = Double(rng.next()), h = Double(rng.next()) * H
                    let p = a + (b - a) * t
                    dot(SIMD3(p.x, h, p.y), 0.42)
                }
                // Top and bottom edges crisp.
                for i in 0...Int(len * 14) {
                    let p = a + (b - a) * (Double(i) / (len * 14))
                    dot(SIMD3(p.x, 0, p.y), 0.75); dot(SIMD3(p.x, H, p.y), 0.55)
                }
            }
            // Furniture blocks: sofa, table, bed.
            let boxes: [(SIMD3<Double>, SIMD3<Double>)] = [
                ([1.0, 0, 3.6], [3.2, 0.85, 4.6]), ([1.6, 0, 2.0], [2.8, 0.45, 2.7]), ([5.6, 0, 3.4], [7.4, 0.6, 5.6]),
            ]
            for (lo, hi) in boxes {
                for _ in 0..<(density / 25) {
                    let p = SIMD3(lo.x + (hi.x - lo.x) * Double(rng.next()), hi.y, lo.z + (hi.z - lo.z) * Double(rng.next()))
                    dot(p, 0.55)
                    let side = SIMD3(lo.x + (hi.x - lo.x) * Double(rng.next()), hi.y * Double(rng.next()), hi.z)
                    dot(side, 0.4)
                }
            }
        }
    }
}

struct Phone: View {
    let image: NSImage
    let height: CGFloat
    var body: some View {
        let w = height * 1320 / 2868
        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            .frame(width: w, height: height)
            .clipShape(RoundedRectangle(cornerRadius: w * 0.135, style: .continuous))
            .padding(w * 0.025)
            .background(RoundedRectangle(cornerRadius: w * 0.16, style: .continuous).fill(Color(white: 0.09)))
            .overlay(RoundedRectangle(cornerRadius: w * 0.16, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: w * 0.006))
            .shadow(color: .black.opacity(0.55), radius: w * 0.08, y: w * 0.04)
    }
}

struct Guides: View {
    let safe: CGRect
    var body: some View {
        GeometryReader { _ in
            Rectangle().stroke(Color.red, lineWidth: 6).frame(width: safe.width, height: safe.height)
                .position(x: safe.midX, y: safe.midY)
        }
    }
}

// MARK: Header 3840 x 1646, safe 1646 x 661 at (1097, 493)
struct Header: View {
    var guides: Bool
    let safe = CGRect(x: 1097, y: 493, width: 1646, height: 661)
    var body: some View {
        ZStack {
            LinearGradient(colors: [tile, bg], startPoint: .top, endPoint: .bottom)
            PointRoom(focus: CGPoint(x: 0.5, y: 0.66), scale: 1.55, density: 30000)
            // Keep the centre calm behind the wordmark.
            Ellipse().fill(RadialGradient(colors: [bg.opacity(0.95), bg.opacity(0.75), .clear], center: .center, startRadius: 0, endRadius: 1000))
                .frame(width: 2300, height: 1000)
            HStack(spacing: 64) {
                TildaMark(cornerRatio: 0.225).frame(width: 400, height: 400)
                    .shadow(color: teal.opacity(0.25), radius: 60)
                VStack(alignment: .leading, spacing: 18) {
                    Text("Tilda").font(.system(size: 250, weight: .bold)).foregroundStyle(.white)
                        .kerning(-6)
                    Text("Rooms and objects in 3D, with LiDAR")
                        .font(.system(size: 64, weight: .medium)).foregroundStyle(tealText)
                }
            }
            .frame(width: safe.width, height: safe.height)
            .position(x: safe.midX, y: safe.midY)
            if guides { Guides(safe: safe) }
        }
        .frame(width: 3840, height: 1646)
    }
}

// MARK: Search result 3840 x 2560, safe 2168 x 1030 at (836, 765)
struct Search: View {
    var guides: Bool
    let shots: [NSImage]
    let safe = CGRect(x: 836, y: 765, width: 2168, height: 1030)
    var body: some View {
        ZStack {
            LinearGradient(colors: [tile, bg], startPoint: .top, endPoint: .bottom)
            PointRoom(focus: CGPoint(x: 0.5, y: 0.62), scale: 1.0, density: 30000)
            Ellipse().fill(RadialGradient(colors: [bg.opacity(0.95), bg.opacity(0.7), .clear], center: .center, startRadius: 0, endRadius: 1300))
                .frame(width: 2800, height: 1500)
            HStack(alignment: .center, spacing: 56) {
                VStack(alignment: .leading, spacing: 34) {
                    HStack(spacing: 28) {
                        TildaMark(cornerRatio: 0.225).frame(width: 128, height: 128)
                        Text("Tilda").font(.system(size: 104, weight: .bold)).foregroundStyle(.white).kerning(-3)
                    }
                    Text("Scan a room.\nGet the floor plan\nand square footage.")
                        .font(.system(size: 72, weight: .semibold)).foregroundStyle(.white)
                        .lineSpacing(6).fixedSize()
                    Text("LiDAR scans of rooms, objects and spaces")
                        .font(.system(size: 36, weight: .medium)).foregroundStyle(tealText).fixedSize()
                }
                .frame(width: 700, alignment: .leading)
                HStack(alignment: .center, spacing: 36) {
                    Phone(image: shots[0], height: 830)
                    Phone(image: shots[1], height: 930)
                    Phone(image: shots[2], height: 830)
                }
            }
            .frame(width: safe.width, height: safe.height)
            .position(x: safe.midX, y: safe.midY)
            if guides { Guides(safe: safe) }
        }
        .frame(width: 3840, height: 2560)
    }
}

@MainActor func save<V: View>(_ view: V, _ w: Int, _ h: Int, _ path: String) {
    let r = ImageRenderer(content: view.environment(\.colorScheme, .dark))
    r.scale = 1; r.isOpaque = true
    guard let cg = r.cgImage else { fatalError("render failed \(path)") }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) \(cg.width)x\(cg.height)")
}

MainActor.assumeIsolated {
    let a = CommandLine.arguments
    let shotsDir = a[1], out = a[2], guides = a.contains("--guides")
    let names = ["01-home.jpg", "02-room-summary.jpg", "03-whole-floor.jpg"]
    let shots = names.map { NSImage(contentsOfFile: "\(shotsDir)/\($0)")! }
    let suffix = guides ? "-guides" : ""
    save(Header(guides: guides), 3840, 1646, "\(out)/header\(suffix).png")
    save(Search(guides: guides, shots: shots), 3840, 2560, "\(out)/search\(suffix).png")
}
