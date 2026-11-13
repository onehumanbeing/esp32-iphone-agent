// Vision OCR lines for one image as JSON [[text, [x1,y1,x2,y2]]], the same call as UITreeOCR.lines defaults.
import CoreGraphics
import Foundation
import ImageIO
import Vision

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let src = CGImageSourceCreateWithURL(url as CFURL, nil)!
let image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let w = Double(image.width), h = Double(image.height)
func px(_ b: CGRect) -> [Int] { [Int(b.minX * w), Int((1 - b.maxY) * h), Int(b.maxX * w), Int((1 - b.minY) * h)] }
let req = VNRecognizeTextRequest()
req.recognitionLevel = .accurate
req.recognitionLanguages = ["zh-Hans", "en-US"]
req.usesLanguageCorrection = false
try VNImageRequestHandler(cgImage: image).perform([req])
var out: [[Any]] = []
for o in req.results ?? [] {
    guard let top = o.topCandidates(1).first, !top.string.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
    let words = top.string.split(whereSeparator: \.isWhitespace)
    if words.count <= 1 { out.append([top.string, px(o.boundingBox)]); continue }
    for word in words {
        if let r = try? top.boundingBox(for: word.startIndex..<word.endIndex) { out.append([String(word), px(r.boundingBox)]) }
    }
}
print(String(data: try JSONSerialization.data(withJSONObject: out), encoding: .utf8)!)
