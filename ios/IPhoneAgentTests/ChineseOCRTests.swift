import XCTest
import UIKit
@testable import IPhoneAgent

/// Chinese labels must come through the OCR that open and the Chinese typer read the screen with.
@MainActor final class ChineseOCRTests: XCTestCase {
    /// A white screen (the size of a mirrored frame) with `labels` drawn in rows, `points` high.
    static func screen(_ rows: [[String]], points: CGFloat = 22, size: CGSize = CGSize(width: 718, height: 1554)) -> CGImage {
        UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            let font = UIFont.systemFont(ofSize: points)
            for (r, row) in rows.enumerated() {
                for (c, label) in row.enumerated() {
                    (label as NSString).draw(at: CGPoint(x: 40 + CGFloat(c) * 150, y: 200 + CGFloat(r) * 120),
                                             withAttributes: [.font: font, .foregroundColor: UIColor.black])
                }
            }
        }.cgImage!
    }

    func testAutomaticLanguagesReadChineseAppLabels() async {
        let lines = await UITreeOCR.lines(Self.screen([["时钟", "备忘录", "设置"], ["App Store", "微信", "日历"]]),
                                          languages: nil).map(\.text)
        for label in ["时钟", "备忘录", "设置", "微信", "日历", "App Store"] {
            XCTAssertTrue(lines.contains { $0.contains(label) }, "\(label) not in \(lines)")
        }
    }

    /// One Chinese label on a mostly English screen: Vision's automatic language pick must not drop it.
    func testAutomaticLanguagesKeepAChineseLabelAmongEnglish() async {
        let rows = [["Settings", "Messages", "Calendar"], ["Weather", "时钟", "Photos"], ["Notes", "Wallet", "Maps"]]
        let lines = await UITreeOCR.lines(Self.screen(rows), languages: nil).map(\.text)
        XCTAssertTrue(lines.contains { $0.contains("时钟") }, "\(lines)")
    }

    /// Small candidate-bar-sized words, read with the explicit languages the typer uses.
    func testSmallChineseWordsReadWithExplicitLanguages() async {
        let lines = await UITreeOCR.lines(Self.screen([["今天", "金天", "今", "进"]], points: 15)).map(\.text)
        for word in ["今天", "金天"] { XCTAssertTrue(lines.contains(word), "\(word) not in \(lines)") }
    }

    /// The automatic pick (languages nil) read 金天 but dropped 今天 at 15 pt in the simulator: open reads
    /// Chinese names with zh-Hans named, whole lines kept.
    func testOpenReadsSmallChineseNamesWithChineseNamedAndLinesWhole() async {
        let image = Self.screen([["今天", "金天"], ["App Store"]], points: 15)
        let named = await UITreeOCR.lines(image, languages: UITreeOCR.chinese, whole: true).map(\.text)
        XCTAssertTrue(named.contains("今天") && named.contains("金天") && named.contains("App Store"), "\(named)")
    }

    /// The pinyin keyboard's candidate bar: tight cells that Vision reads as one word without spaces. With `cells`
    /// the typer gets them one by one (北 among them: "not among the candidates for bei", 2026-11-11).
    func testTheTightCandidateBarIsReadCellByCell() async {
        let bar = ["北方", "北方人", "北房", "被", "杯", "背", "倍", "北"]
        let size = CGSize(width: 718, height: 1560)
        let image = UIGraphicsImageRenderer(size: size, format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { ctx in
            UIColor(white: 0.82, alpha: 1).setFill(); ctx.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 32), .foregroundColor: UIColor.black]
            var x: CGFloat = 18
            for word in bar {
                (word as NSString).draw(at: CGPoint(x: x, y: 1022), withAttributes: attributes)
                x += (word as NSString).size(withAttributes: attributes).width + 30
            }
        }.cgImage!
        let whole = await UITreeOCR.lines(image).map(\.text)
        let cells = await UITreeOCR.lines(image, cells: true).map(\.text)
        XCTAssertTrue(bar.allSatisfy(cells.contains), "cells \(cells), lines \(whole)")
    }
}
