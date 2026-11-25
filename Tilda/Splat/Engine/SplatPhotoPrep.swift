import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

/// Looks at each photo before training, using Apple's on-device Vision models (no network, no Private Cloud Compute):
/// how sharp it is, and whether a person is in it (so people walking through are not baked into the splat).
enum SplatPhotoPrep {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Size of the greyscale copy used for the sharpness score. Small is enough and keeps this cheap.
    static let sharpnessWidth = 480

    /// Sharpness score (variance of the Laplacian) of one photo, or nil when it cannot be read.
    static func sharpness(of url: URL) -> Float? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: sharpnessWidth,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let w = cg.width, h = cg.height
        var gray = [UInt8](repeating: 0, count: w * h)
        let ok = gray.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? SplatMath.laplacianVariance(gray: gray, width: w, height: h) : nil
    }

    /// Pixel size of a photo from its header, without decoding it.
    static func pixelSize(of url: URL) -> (width: Int, height: Int)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { return nil }
        return (w, h)
    }

    /// If a person is in the photo, writes a mask PNG the same size as the photo (white = keep, black = person,
    /// slightly grown so edges and shadows are covered) to `maskURL` and returns true. Returns false when nobody is
    /// there (or the model could not run), so the frame trains without a mask.
    ///
    /// `orientation` says how to turn the raw landscape photo upright: the person model works far better on upright
    /// people, and the mask is turned back to sensor pixels afterwards.
    static func writePersonMask(for url: URL, size: (width: Int, height: Int), orientation: CGImagePropertyOrientation,
                                to maskURL: URL) -> Bool {
        guard size.width > 0, size.height > 0,
              let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return false }
        // The model works at a fixed small size anyway; a 1024 px copy keeps it quick.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: 1024,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return false }

        // Vision's classic person-segmentation request: the same on-device model as the Swift-concurrency
        // `GeneratePersonSegmentationRequest`, but synchronous, which suits this background worker.
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        do { try VNImageRequestHandler(cgImage: cg, orientation: orientation).perform([request]) } catch { return false }
        guard let buffer = request.results?.first?.pixelBuffer else { return false }
        guard personFraction(buffer) > 0.002 else { return false }

        // Scale the upright mask to the upright photo size, turn it back into sensor pixels, grow it, then invert.
        let swapped = orientation == .left || orientation == .right
        let uprightW = CGFloat(swapped ? size.height : size.width), uprightH = CGFloat(swapped ? size.width : size.height)
        var mask = CIImage(cvPixelBuffer: buffer)
        mask = mask.transformed(by: CGAffineTransform(scaleX: uprightW / mask.extent.width, y: uprightH / mask.extent.height))
        mask = mask.oriented(SplatMath.inverse(of: orientation))
        mask = mask.transformed(by: CGAffineTransform(translationX: -mask.extent.minX, y: -mask.extent.minY))
        let bounds = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        let grow = max(2, Double(max(size.width, size.height)) * 0.006)   // ~12 px on a 1920 px photo
        guard let dilate = CIFilter(name: "CIMorphologyMaximum", parameters: [kCIInputImageKey: mask.clampedToExtent(),
                                                                              kCIInputRadiusKey: grow]),
              let grown = dilate.outputImage,
              let invert = CIFilter(name: "CIColorInvert", parameters: [kCIInputImageKey: grown.cropped(to: bounds)]),
              let keep = invert.outputImage?.cropped(to: bounds),
              let png = ciContext.pngRepresentation(of: keep, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray())
        else { return false }
        return (try? png.write(to: maskURL)) != nil
    }

    /// Share of pixels the model calls "person" (0...1).
    private static func personFraction(_ buffer: CVPixelBuffer) -> Double {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        guard w > 0, h > 0 else { return 0 }
        var hits = 0
        for y in 0..<h {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0..<w where row[x] > 128 { hits += 1 }
        }
        return Double(hits) / Double(w * h)
    }
}
