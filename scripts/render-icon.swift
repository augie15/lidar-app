import SwiftUI
import AppKit

// Compiled together with Tilda/Theme/TildaMark.swift by render-icon.sh.
@MainActor func render(to path: String) {
    let view = TildaMark(cornerRatio: 0).frame(width: 1024, height: 1024)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    renderer.isOpaque = true
    guard let cg = renderer.cgImage else { fatalError("render failed") }
    // Redraw onto an opaque RGB context so the PNG has no alpha channel.
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
MainActor.assumeIsolated { render(to: CommandLine.arguments[1]) }
