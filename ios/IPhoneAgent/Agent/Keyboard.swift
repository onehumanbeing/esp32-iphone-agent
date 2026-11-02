import Vision

/// Which layout the on-screen keyboard shows, read from the screen: the pinyin keyboard labels its space bar
/// (拼音 / 空格) and shows 选定 / 确认 on its return key; the English one shows "space" or nothing.
enum KeyboardLayout: Equatable {
    case english, pinyin, none

    static func read(_ jpeg: Data) async -> KeyboardLayout {
        guard let image = Vision.image(jpeg) else { return .none }
        let words = await text(in: image)
        if words.contains(where: { $0.contains("拼") || $0.contains("空格") || $0.contains("选定") }) {
            return .pinyin
        }
        if words.contains(where: { ["space", "return", "qwertyuiop"].contains($0.lowercased().replacingOccurrences(of: " ", with: "")) }) {
            return .english
        }
        return words.isEmpty ? .none : .english
    }

    /// Text in the keyboard's bottom rows (space bar and return key), so a page's own text rarely counts.
    private static func text(in image: CGImage) async -> [String] {
        await withCheckedContinuation { done in
            let request = VNRecognizeTextRequest { request, _ in
                done.resume(returning: (request.results as? [VNRecognizedTextObservation] ?? [])
                    .compactMap { $0.topCandidates(1).first?.string })
            }
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = false
            request.regionOfInterest = CGRect(x: 0, y: 0, width: 1, height: 0.18)  // Vision: origin bottom-left
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { done.resume(returning: []) }
            }
        }
    }
}
