import CoreGraphics
import Foundation
import Vision

/// The OCR half of the virtual UI tree: Apple Vision text lines as pixel boxes, like tree.py ocr_lines()
/// (which reads PP-OCR quads on Spark). Same request as Keyboard.swift: accurate, zh-Hans + en-US.
enum UITreeOCR {
    static func lines(_ image: CGImage) async -> [(text: String, box: [Int])] {
        let w = Double(image.width), h = Double(image.height)
        return await withCheckedContinuation { done in
            let request = VNRecognizeTextRequest { request, _ in
                let lines = (request.results as? [VNRecognizedTextObservation] ?? []).compactMap { o -> (text: String, box: [Int])? in
                    guard let text = o.topCandidates(1).first?.string,
                          !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                    let b = o.boundingBox  // normalized, origin bottom-left
                    return (text, [Int(b.minX * w), Int((1 - b.maxY) * h), Int(b.maxX * w), Int((1 - b.minY) * h)])
                }
                done.resume(returning: lines)
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
