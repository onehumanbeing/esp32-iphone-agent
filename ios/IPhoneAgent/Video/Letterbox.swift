import CoreGraphics
import Foundation

/// Black bars around the mirrored screen. AirPlay fits the device's screen into the display the board advertises;
/// when the frame it sends is not the screen's shape (a square display, an iPad turned inside a landscape one, a
/// phone whose shape differs from the display), the rest is black. Those bars are cropped off before anything sees
/// the frame (the model, Vision, the pointer search, OCR, the review), so the screenshot is the screen and its
/// 0-1000 coordinates are screen fractions.
///
/// Where the screen sits follows from the two shapes: centred, fitted, in one of two orientations. A bar is only
/// cropped when it really is black (a dark app's edge is not a bar), and a frame that already has the screen's
/// shape, as an iPhone's 718x1560 stream does, is left whole.
struct Letterbox {
    /// The device screen in pixels, either way round (UIScreen.nativeBounds); zero: unknown, nothing is cropped.
    var screen: CGSize = .zero
    /// The orientation chosen last, for a frame where both fit (a square one with dark content): true = landscape.
    var landscape: Bool?

    /// Aspects this close to the screen's (relative) are the screen.
    static let tolerance = 0.015
    /// Bars thinner than this share of the frame are left (rounding, an encoder's padding).
    static let least = 0.01
    /// A bar's pixels are at most this bright (0-255), after averaging down to a small sample.
    static let darkest: UInt8 = 24

    /// The screen's part of a `width` x `height` frame in pixels (top-left origin, even sizes), or nil for the whole
    /// frame. `black(rect)` says whether that part of the frame is all black.
    mutating func content(width: Int, height: Int, black: (CGRect) -> Bool) -> CGRect? {
        guard width > 0, height > 0, screen.width > 0, screen.height > 0 else { return nil }
        let frame = Double(width) / Double(height)
        let long = Double(max(screen.width, screen.height)), short = Double(min(screen.width, screen.height))
        let shapes = [(landscape: false, aspect: short / long), (landscape: true, aspect: long / short)]
        if shapes.contains(where: { abs(frame - $0.aspect) / $0.aspect < Self.tolerance }) {
            landscape = frame > 1
            return nil
        }
        let fits = shapes.compactMap { shape -> (landscape: Bool, rect: CGRect)? in
            let rect = Self.fit(shape.aspect, width: width, height: height)
            let bars = Self.bars(rect, width: width, height: height)
            guard !bars.isEmpty, bars.allSatisfy(black) else { return nil }
            return (shape.landscape, rect)
        }
        let pick = fits.count == 1 ? fits.first : fits.first { $0.landscape == landscape }
        guard let pick else { return nil }
        landscape = pick.landscape
        return pick.rect
    }

    /// The `aspect` rectangle fitted and centred in the frame, in whole even pixels.
    static func fit(_ aspect: Double, width: Int, height: Int) -> CGRect {
        func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
        if Double(width) / Double(height) > aspect {  // pillarbox: bars left and right
            let w = min(width, even(Double(height) * aspect))
            return CGRect(x: (width - w) / 2, y: 0, width: w, height: height)
        }
        let h = min(height, even(Double(width) / aspect))  // letterbox: bars top and bottom
        return CGRect(x: 0, y: (height - h) / 2, width: width, height: h)
    }

    /// The frame outside `rect`, as the bars on its two sides; none when they are too thin to matter.
    static func bars(_ rect: CGRect, width: Int, height: Int) -> [CGRect] {
        let w = CGFloat(width), h = CGFloat(height)
        if rect.width < w {
            guard (w - rect.width) / w >= CGFloat(least) else { return [] }
            return [CGRect(x: 0, y: 0, width: rect.minX, height: h), CGRect(x: rect.maxX, y: 0, width: w - rect.maxX, height: h)]
                .filter { $0.width >= 1 }
        }
        guard (h - rect.height) / h >= CGFloat(least) else { return [] }
        return [CGRect(x: 0, y: 0, width: w, height: rect.minY), CGRect(x: 0, y: rect.maxY, width: w, height: h - rect.maxY)]
            .filter { $0.height >= 1 }
    }

    /// Whether `rect` of `image` is black: drawn down to at most 32x32 gray samples, none brighter than `darkest`.
    static func isBlack(_ image: CGImage, _ rect: CGRect) -> Bool {
        guard let part = image.cropping(to: rect.integral) else { return false }
        let w = max(1, min(32, part.width)), h = max(1, min(32, part.height))
        var pixels = [UInt8](repeating: 255, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(part, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn && pixels.allSatisfy { $0 <= darkest }
    }
}
