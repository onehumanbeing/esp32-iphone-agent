import Vision
import XCTest
@testable import IPhoneAgent

/// Accented Latin letters through Option keys, app names in the device's language, OCR in that language.
@MainActor final class LocalizationTests: XCTestCase {
    func testAccentedLettersGoThroughDeadKeys() {
        let (strokes, typed) = Accents.plan("Café Ñandú")
        XCTAssertEqual(strokes, [.text("Caf"), .key("alt+e"), .text("e "), .key("alt+n"), .text("Nand"),
                                 .key("alt+e"), .text("u")])
        XCTAssertEqual(typed, "Café Ñandú")
    }

    func testEachMarkHasItsDeadKey() {
        let cases: [(String, [Accents.Stroke])] = [
            ("à", [.key("alt+`"), .text("a")]), ("ê", [.key("alt+i"), .text("e")]), ("ü", [.key("alt+u"), .text("u")]),
            ("Ö", [.key("alt+u"), .text("O")]), ("õ", [.key("alt+n"), .text("o")]), ("ÿ", [.key("alt+u"), .text("y")]),
        ]
        for (text, strokes) in cases { XCTAssertEqual(Accents.plan(text).strokes, strokes, text) }
    }

    func testLettersOfTheirOwnNeedNoSecondKey() {
        XCTAssertEqual(Accents.plan("ça").strokes, [.key("alt+c"), .text("a")])
        XCTAssertEqual(Accents.plan("Straße").strokes, [.text("Stra"), .key("alt+s"), .text("e")])
        XCTAssertEqual(Accents.plan("¿Qué?").strokes, [.key("alt+shift+/"), .text("Qu"), .key("alt+e"), .text("e?")])
        XCTAssertEqual(Accents.plan("Œuvre").strokes, [.key("alt+shift+q"), .text("uvre")])
    }

    func testDecomposedAccentsAreTheSameLetters() {
        XCTAssertEqual(Accents.plan("e\u{301}t\u{65}\u{301}").strokes, [.key("alt+e"), .text("et"), .key("alt+e"), .text("e")])
    }

    func testOtherNonASCIIIsStillFoldedOrDropped() {
        let (strokes, typed) = Accents.plan("ok 👍 ł")
        XCTAssertEqual(strokes, [.text("ok  ")], "ł has no Option key and does not fold")
        XCTAssertEqual(typed, "ok  ")
        XCTAssertTrue(Accents.typeable("Réglages"))
        XCTAssertFalse(Accents.typeable("メモ"))
    }

    func testTheTyperSendsTheOptionKeys() async throws {
        var sent: [String] = []
        let typer = HanTyper(send: { sent.append("type \($0)") }, key: { sent.append("key \($0)") },
                             toggle: { sent.append("toggle") }, look: { nil })
        let note = try await typer.type("café")
        XCTAssertNil(note)
        XCTAssertEqual(sent, ["type caf", "key alt+e", "type e"])
    }

    func testDeviceLanguageNamesComeFirstWhenTheBoardCanTypeThem() {
        XCTAssertEqual(AppNames.alternatives("闹钟", language: "zh"), ["时钟", "Clock"])
        XCTAssertEqual(AppNames.alternatives("闹钟", language: "en"), ["Clock", "时钟"])
        XCTAssertEqual(AppNames.alternatives("Alarm", language: "de"), ["Uhr", "Clock"])
        XCTAssertEqual(AppNames.alternatives("Settings", language: "fr"), ["Réglages"])
        XCTAssertEqual(AppNames.alternatives("Settings", language: "es"), ["Ajustes"])
        XCTAssertEqual(AppNames.alternatives("Settings", language: "es-419"), ["Configuración"])
        XCTAssertEqual(AppNames.alternatives("Settings", language: "pt-PT"), ["Definições"])
        XCTAssertEqual(AppNames.alternatives("Weather", language: "pt-PT"), ["Tempo"], "falls back to pt")
        XCTAssertEqual(AppNames.alternatives("Notes", language: "ja"), ["备忘录"], "kana the board cannot type")
        XCTAssertEqual(AppNames.alternatives("Health", language: "de"), ["健康"], "German says Health")
    }

    func testLocalizedNamesFindTheirApp() {
        XCTAssertEqual(AppNames.alternatives("Uhr", language: "en"), ["Clock", "时钟"])
        XCTAssertEqual(AppNames.alternatives("réglages", language: "en"), ["Settings", "设置"])
        XCTAssertEqual(AppNames.alternatives("メモ", language: "ja"), ["Notes", "备忘录"])
        XCTAssertEqual(AppNames.alternatives("미리 알림", language: "ko"), ["Reminders", "提醒事项"])
        XCTAssertEqual(AppNames.alternatives("Duolingo", language: "de"), [])
    }

    func testEveryNameBelongsToOneApp() {
        var owner: [String: String] = [:]
        for row in AppNames.table {
            for name in Set((row + (AppNames.localized[row[1]].map { Array($0.values) } ?? [])).map(AppNames.norm)) {
                XCTAssertTrue(owner[name] == nil, "\(name): \(owner[name] ?? "") and \(row[1])")
                owner[name] = row[1]
            }
        }
        XCTAssertTrue(AppNames.localized.keys.allSatisfy { en in AppNames.table.contains { $0[1] == en } })
    }

    func testLanguageTags() {
        XCTAssertEqual(AppNames.language("de-DE"), "de")
        XCTAssertEqual(AppNames.language("es-ES"), "es")
        XCTAssertEqual(AppNames.language("es-MX"), "es-419")
        XCTAssertEqual(AppNames.language("pt-BR"), "pt")
        XCTAssertEqual(AppNames.language("pt-PT"), "pt-PT")
        XCTAssertEqual(AppNames.language("zh-Hans-CN"), "zh")
        XCTAssertEqual(AppNames.language("zh-TW"), "zh-Hant")
        XCTAssertEqual(AppNames.language("ja-JP"), "ja")
    }

    func testOCRAddsTheDeviceLanguageWhenVisionReadsIt() {
        let supported = ["en-US", "fr-FR", "de-DE", "zh-Hans", "zh-Hant", "ja-JP", "ko-KR", "pt-BR"]
        XCTAssertEqual(UITreeOCR.withLanguage("fr-CA", supported: supported), ["fr-FR", "zh-Hans", "en-US"])
        XCTAssertEqual(UITreeOCR.withLanguage("pt-PT", supported: supported), ["pt-BR", "zh-Hans", "en-US"])
        XCTAssertEqual(UITreeOCR.withLanguage("zh-TW", supported: supported), ["zh-Hant", "zh-Hans", "en-US"])
        XCTAssertEqual(UITreeOCR.withLanguage("zh-Hans-CN", supported: supported), UITreeOCR.chinese)
        XCTAssertEqual(UITreeOCR.withLanguage("en-GB", supported: supported), UITreeOCR.chinese)
        XCTAssertEqual(UITreeOCR.withLanguage("hu-HU", supported: supported), UITreeOCR.chinese)
        let french = ["fr-FR"] + UITreeOCR.chinese
        XCTAssertEqual(UITreeOCR.languages(for: "Réglages", device: french), french)
        XCTAssertNil(UITreeOCR.languages(for: "Réglages", device: UITreeOCR.chinese), "Vision's own pick, as before")
        XCTAssertEqual(UITreeOCR.languages(for: "Notes", device: UITreeOCR.chinese), UITreeOCR.chinese)
    }

    func testVisionReadsAppNamesWithTheDeviceLanguageNamed() async throws {
        let supported = try VNRecognizeTextRequest().supportedRecognitionLanguages()
        let rows: [(String, [String])] = [("fr-FR", ["Réglages", "Météo"]), ("de-DE", ["Übersetzen", "Bücher"]),
                                          ("ja-JP", ["メモ", "カレンダー"]), ("ko-KR", ["메모", "날씨"]), ("zh-Hans", ["设置", "时钟"])]
        for (preferred, labels) in rows {
            let languages = UITreeOCR.withLanguage(preferred, supported: supported)
            let lines = await UITreeOCR.lines(ChineseOCRTests.screen([labels, ["App Store"]], points: 20), languages: languages, whole: true)
                .map(\.text)
            for label in labels + ["App Store"] { XCTAssertTrue(lines.contains { $0.contains(label) }, "\(preferred): \(label) not in \(lines)") }
        }
    }
}
