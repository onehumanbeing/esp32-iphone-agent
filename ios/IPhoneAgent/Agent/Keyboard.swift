import Vision

/// Which layout the on-screen keyboard shows, read from the screen: the pinyin keyboard labels its space bar
/// (a small 拼, or 空格) and may show 选定 on its return key; the English one shows nothing there.
enum KeyboardLayout: Equatable {
    case english, pinyin, none

    static func read(_ jpeg: Data) async -> KeyboardLayout {
        guard let image = Vision.image(jpeg), let rows = bottomRows(image) else { return .none }
        let words = await text(in: rows)
        if words.contains(where: { $0.contains("拼") || $0.contains("空格") || $0.contains("选定") }) { return .pinyin }
        return words.contains("123") ? .english : .none  // both layouts have the 123 key
    }

    /// The keyboard's bottom rows, scaled up to ~2000 px wide: the space bar's 拼 is a tiny grey glyph that
    /// text recognition misses at screen size (2026-11-03: missed at 718 px, found at 3x).
    private static func bottomRows(_ image: CGImage) -> CGImage? {
        let h = Double(image.height), w = Double(image.width)
        guard let crop = image.cropping(to: CGRect(x: 0, y: h * 0.78, width: w, height: h * 0.22)) else { return nil }
        let scale = max(1, 2000 / w)
        let size = CGSize(width: Double(crop.width) * scale, height: Double(crop.height) * scale)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(crop, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }

    private static func text(in image: CGImage) async -> [String] {
        await withCheckedContinuation { done in
            let request = VNRecognizeTextRequest { request, _ in
                done.resume(returning: (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string })
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = false
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { done.resume(returning: []) }
            }
        }
    }
}
