import CoreSpotlight
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Indexes scans in Spotlight (name, summary, tags, kind, a small thumbnail) entirely on device.
enum SpotlightIndexer {
    static let domain = "com.augie15.tilda.scans"

    static func index(scan: Scan, insights: ScanInsights?, folder: URL) {
        Task.detached(priority: .utility) {
            let attributes = CSSearchableItemAttributeSet(contentType: .data)
            attributes.title = scan.name
            attributes.displayName = scan.name
            var parts = [scan.kind.title + " scan"]
            if let summary = insights?.summary, !summary.isEmpty { parts.append(summary) }
            attributes.contentDescription = parts.joined(separator: " · ")
            attributes.keywords = [scan.kind.title, "scan", "3D", "LiDAR"] + (insights?.tags ?? [])
            attributes.contentCreationDate = scan.createdAt
            attributes.thumbnailData = thumbnail(folder: folder)
            let item = CSSearchableItem(uniqueIdentifier: scan.id.uuidString, domainIdentifier: domain,
                                        attributeSet: attributes)
            item.expirationDate = .distantFuture
            try? await CSSearchableIndex.default().indexSearchableItems([item])
        }
    }

    static func remove(ids: [UUID]) {
        guard !ids.isEmpty else { return }
        CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: ids.map(\.uuidString)) { _ in }
    }

    /// First keyframe or Object Capture photo, downsampled. Nil when the scan has no photos.
    private static func thumbnail(folder: URL) -> Data? {
        let fm = FileManager.default
        for dir in ["frames/images", "images"] {
            let url = folder.appendingPathComponent(dir, isDirectory: true)
            guard let first = ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                .filter({ ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first,
                  let source = CGImageSourceCreateWithURL(first as CFURL, nil) else { continue }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: dir == "images",
                kCGImageSourceThumbnailMaxPixelSize: 320,
            ]
            guard var cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { continue }
            if dir == "frames/images" { cg = rotatedUpright(cg) ?? cg }
            let data = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
            if CGImageDestinationFinalize(dest) { return data as Data }
        }
        return nil
    }

    /// Keyframes are sensor-landscape; rotate 90 degrees clockwise to portrait.
    private static func rotatedUpright(_ image: CGImage) -> CGImage? {
        let w = image.height, h = image.width
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.translateBy(x: CGFloat(w), y: 0)
        ctx.rotate(by: .pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}
