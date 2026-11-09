import CoreGraphics
import Foundation
import Vision

/// The OCR half of the virtual UI tree: Apple Vision text as pixel boxes, like tree.py ocr_lines()
/// (which reads PP-OCR quads on Spark). Same request as Keyboard.swift: accurate, zh-Hans + en-US.
/// Vision reads whole lines; PP-OCR boxes words, so a line is split at spaces (each word its own `#ID`).
/// `languages` nil: Vision picks them itself (reads kana and other scripts; for the language on the screen), lines
/// stay whole, and unsure lines are dropped (an icon on the home screen read as Arabic, 2026-11-07). That pick
/// drops small Chinese words, though (a candidate bar's 今天 at 15 pt): reads that need Chinese name zh-Hans, and
/// `whole` keeps their lines whole ("App Store" one line).
enum UITreeOCR {
    static let chinese = ["zh-Hans", "en-US"]

    /// The iPhone's own language ahead of `chinese` when Vision reads it (Spotlight lists the apps under their
    /// names in that language). The first language leads: after zh-Hans, Vision dropped French and German
    /// accents and misread kana and Hangul; first, it read them, and Chinese and English still came through.
    static let device: [String] = {
        let supported = (try? VNRecognizeTextRequest().supportedRecognitionLanguages()) ?? []
        return withLanguage(Locale.preferredLanguages.first ?? "en", supported: supported)
    }()

    static func withLanguage(_ preferred: String, supported: [String]) -> [String] {
        func parts(_ id: String) -> (code: String?, script: String?) {
            let full = Locale.Language(identifier: Locale.Language(identifier: id).maximalIdentifier)
            return (full.languageCode?.identifier, full.script?.identifier)
        }
        let want = parts(preferred)
        guard let hit = supported.first(where: { parts($0) == want }), !chinese.contains(where: { parts($0) == want })
        else { return chinese }
        return [hit] + chinese
    }

    /// The languages to read Spotlight's results for an app `name` with: named ones for ASCII and Chinese names
    /// or on a device whose language Vision reads, else Vision's automatic pick (kana and other scripts).
    static func languages(for name: String, device: [String] = device) -> [String]? {
        name.unicodeScalars.allSatisfy(\.isASCII) || HanTyper.isHan(name) || device.count > chinese.count ? device : nil
    }

    static func lines(_ image: CGImage, languages: [String]? = chinese, whole: Bool = false) async -> [(text: String, box: [Int])] {
        let w = Double(image.width), h = Double(image.height)
        func pixels(_ b: CGRect) -> [Int] {  // normalized, origin bottom-left
            [Int(b.minX * w), Int((1 - b.maxY) * h), Int(b.maxX * w), Int((1 - b.minY) * h)]
        }
        return await withCheckedContinuation { done in
            let once = Vision.Once()
            let request = VNRecognizeTextRequest { request, _ in
                guard once.take() else { return }
                let lines = (request.results as? [VNRecognizedTextObservation] ?? []).flatMap { o -> [(text: String, box: [Int])] in
                    guard let top = o.topCandidates(1).first, languages != nil || top.confidence >= 0.5,
                          !top.string.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
                    let text = top.string
                    let words = text.split(whereSeparator: \.isWhitespace)
                    guard words.count > 1, languages != nil, !whole else { return [(text, pixels(o.boundingBox))] }  // whole lines for the language
                    let boxes = words.map { word -> (text: String, box: [Int])? in
                        guard let r = try? top.boundingBox(for: word.startIndex..<word.endIndex) else { return nil }
                        return (String(word), pixels(r.boundingBox))
                    }
                    let split = boxes.compactMap { $0 }
                    return split.count == words.count ? split : [(text, pixels(o.boundingBox))]
                }
                done.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            if let languages { request.recognitionLanguages = languages } else { request.automaticallyDetectsLanguage = true }
            request.usesLanguageCorrection = false
            DispatchQueue.global(qos: .userInitiated).async {
                do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch { if once.take() { done.resume(returning: []) } }
            }
        }
    }
}
