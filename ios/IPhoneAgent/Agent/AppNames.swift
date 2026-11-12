import Foundation

/// What people call an app versus what the Home Screen calls it: "闹钟" is 时钟 on a Chinese iPhone and Clock on
/// an English one, and Spotlight finds neither from "闹钟". `open` tries these when the name itself is not found.
/// System apps under their other names: a name Spotlight does not list ("闹钟") is tried as the app's system
/// name. Rows: Chinese, English, then aliases.
enum AppNames {
    /// One app per row: its Chinese (zh-Hans) system name, its English name, then other names people use.
    static let table: [[String]] = [
        ["时钟", "Clock", "闹钟", "计时器", "秒表", "Alarm", "Alarms", "Timer", "Stopwatch"],
        ["备忘录", "Notes", "笔记", "记事本", "便签", "Notepad", "Note"],
        ["设置", "Settings", "设定", "系统设置", "Preferences"],
        ["相机", "Camera", "拍照", "照相机"],
        ["照片", "Photos", "相册", "图库", "Gallery", "Photo"],
        ["日历", "Calendar", "日程"],
        ["提醒事项", "Reminders", "提醒", "待办", "Reminder"],
        ["信息", "Messages", "短信", "iMessage", "SMS", "Texts"],
        ["电话", "Phone", "拨号", "打电话"],
        ["通讯录", "Contacts", "联系人"],
        ["邮件", "Mail", "邮箱", "Email"],
        ["音乐", "Music", "Apple Music"],
        ["地图", "Maps", "苹果地图", "Apple Maps"],
        ["天气", "Weather"],
        ["计算器", "Calculator", "计算机"],
        ["文件", "Files", "文件管理"],
        ["快捷指令", "Shortcuts", "捷径"],
        ["语音备忘录", "Voice Memos", "录音", "录音机"],
        ["健康", "Health"],
        ["钱包", "Wallet", "Apple Pay"],
        ["查找", "Find My", "查找我的iPhone"],
        ["翻译", "Translate"],
        ["指南针", "Compass"],
        ["图书", "Books", "电子书"],
        ["播客", "Podcasts"],
        ["Safari浏览器", "Safari", "浏览器", "Browser"],
        ["App Store", "App Store", "应用商店", "苹果商店"],
        ["微信", "WeChat", "Weixin"],
        ["支付宝", "Alipay"],
        ["淘宝", "Taobao"],
        ["微博", "Weibo"],
        ["小红书", "Xiaohongshu", "RED"],
        ["哔哩哔哩", "bilibili", "B站"],
        ["高德地图", "Amap", "高德"],
        ["美团", "Meituan"],
        ["京东", "JD"],
        ["KakaoTalk", "KakaoTalk", "Kakao"],  // no Chinese name: the English one twice
        ["Mercari", "Mercari"],
    ]

    /// Apple's names for the system apps in other languages, by English name and language (`language(_:)`).
    static let localized: [String: [String: String]] = [
        "Clock": ["de": "Uhr", "fr": "Horloge", "es": "Reloj", "es-419": "Reloj", "it": "Orologio", "pt": "Relógio",
                  "pt-PT": "Relógio", "ja": "時計", "ko": "시계"],
        "Notes": ["de": "Notizen", "fr": "Notes", "es": "Notas", "es-419": "Notas", "it": "Note", "pt": "Notas",
                  "pt-PT": "Notas", "ja": "メモ", "ko": "메모"],
        "Settings": ["de": "Einstellungen", "fr": "Réglages", "es": "Ajustes", "es-419": "Configuración",
                     "it": "Impostazioni", "pt": "Ajustes", "pt-PT": "Definições", "ja": "設定", "ko": "설정"],
        "Camera": ["de": "Kamera", "fr": "Appareil photo", "es": "Cámara", "es-419": "Cámara", "it": "Fotocamera",
                   "pt": "Câmera", "pt-PT": "Câmara", "ja": "カメラ", "ko": "카메라"],
        "Photos": ["de": "Fotos", "fr": "Photos", "es": "Fotos", "es-419": "Fotos", "it": "Foto", "pt": "Fotos",
                   "pt-PT": "Fotos", "ja": "写真", "ko": "사진"],
        "Calendar": ["de": "Kalender", "fr": "Calendrier", "es": "Calendario", "es-419": "Calendario",
                     "it": "Calendario", "pt": "Calendário", "pt-PT": "Calendário", "ja": "カレンダー", "ko": "캘린더"],
        "Reminders": ["de": "Erinnerungen", "fr": "Rappels", "es": "Recordatorios", "es-419": "Recordatorios",
                      "it": "Promemoria", "pt": "Lembretes", "ja": "リマインダー", "ko": "미리 알림"],
        "Messages": ["de": "Nachrichten", "fr": "Messages", "es": "Mensajes", "es-419": "Mensajes", "it": "Messaggi",
                     "pt": "Mensagens", "pt-PT": "Mensagens", "ja": "メッセージ", "ko": "메시지"],
        "Phone": ["de": "Telefon", "fr": "Téléphone", "es": "Teléfono", "es-419": "Teléfono", "it": "Telefono",
                  "pt": "Telefone", "pt-PT": "Telefone", "ja": "電話", "ko": "전화"],
        "Contacts": ["de": "Kontakte", "fr": "Contacts", "es": "Contactos", "es-419": "Contactos", "it": "Contatti",
                     "pt": "Contatos", "pt-PT": "Contactos", "ja": "連絡先", "ko": "연락처"],
        "Mail": ["de": "Mail", "fr": "Mail", "es": "Mail", "es-419": "Mail", "it": "Mail", "pt": "Mail", "ja": "メール",
                 "ko": "메일"],
        "Music": ["de": "Musik", "fr": "Musique", "es": "Música", "es-419": "Música", "it": "Musica", "pt": "Música",
                  "pt-PT": "Música", "ja": "ミュージック", "ko": "음악"],
        "Maps": ["de": "Karten", "fr": "Plans", "es": "Mapas", "es-419": "Mapas", "it": "Mappe", "pt": "Mapas",
                 "pt-PT": "Mapas", "ja": "マップ", "ko": "지도"],
        "Weather": ["de": "Wetter", "fr": "Météo", "es": "Tiempo", "es-419": "Clima", "it": "Meteo", "pt": "Tempo",
                    "ja": "天気", "ko": "날씨"],
        "Calculator": ["de": "Rechner", "fr": "Calculette", "es": "Calculadora", "es-419": "Calculadora",
                       "it": "Calcolatrice", "pt": "Calculadora", "pt-PT": "Calculadora", "ja": "計算機", "ko": "계산기"],
        "Files": ["de": "Dateien", "fr": "Fichiers", "es": "Archivos", "es-419": "Archivos", "it": "File",
                  "pt": "Arquivos", "pt-PT": "Ficheiros", "ja": "ファイル", "ko": "파일"],
        "Shortcuts": ["de": "Kurzbefehle", "fr": "Raccourcis", "es": "Atajos", "es-419": "Atajos",
                      "it": "Comandi Rapidi", "pt": "Atalhos", "ja": "ショートカット", "ko": "단축어"],
        "Voice Memos": ["de": "Sprachmemos", "fr": "Dictaphone", "es": "Notas de voz", "es-419": "Notas de voz",
                        "it": "Memo Vocali", "ja": "ボイスメモ", "ko": "음성 메모"],
        "Health": ["fr": "Santé", "es": "Salud", "es-419": "Salud", "it": "Salute", "pt": "Saúde", "pt-PT": "Saúde",
                   "ja": "ヘルスケア", "ko": "건강"],
        "Find My": ["de": "Wo ist?", "fr": "Localiser", "es": "Buscar", "es-419": "Buscar", "pt": "Buscar",
                    "ja": "探す", "ko": "나의 찾기"],
        "Translate": ["de": "Übersetzen", "fr": "Traduire", "es": "Traducir", "es-419": "Traducir", "it": "Traduci",
                      "pt": "Traduzir", "pt-PT": "Traduzir", "ja": "翻訳", "ko": "번역"],
        "Compass": ["de": "Kompass", "fr": "Boussole", "es": "Brújula", "es-419": "Brújula", "it": "Bussola",
                    "pt": "Bússola", "pt-PT": "Bússola", "ja": "コンパス", "ko": "나침반"],
        "Books": ["de": "Bücher", "fr": "Livres", "es": "Libros", "es-419": "Libros", "it": "Libri", "pt": "Livros",
                  "pt-PT": "Livros", "ja": "ブック", "ko": "도서"],
        "Wallet": ["ko": "지갑"],
        "Podcasts": ["ja": "Podcast", "ko": "팟캐스트"],
        // well-known apps whose Home Screen name is in the local script
        "KakaoTalk": ["ko": "카카오톡"],
        "Mercari": ["ja": "メルカリ"],
    ]

    /// Words that name an app but mostly mean something else in a task ("on my phone", "a photo of", "设置一个").
    static let loose: Set<String> = ["Phone", "Photo", "Note", "Texts", "Browser", "Email", "Timer", "Alarm", "Reminder",
                                     "设置", "设定", "提醒", "录音", "拍照", "日程", "待办", "浏览器", "邮箱", "笔记"]

    /// The one app the task names, as the task writes it, so a run can open it before the first look rather
    /// than page the Home Screen for it. nil when it names none, or more than one app.
    static func only(in task: String) -> String? {
        var found: [(row: Int, name: String)] = []
        for (i, row) in table.enumerated() {
            let hit = row.first { name in
                guard name.count >= 2, !loose.contains(name) else { return false }
                if name.allSatisfy(\.isASCII) {
                    let pattern = "(?<![A-Za-z])" + NSRegularExpression.escapedPattern(for: name) + "(?![A-Za-z])"
                    return task.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
                }
                return task.contains(name)
            }
            if let hit, !found.contains(where: { $0.row == i }) { found.append((i, hit)) }
        }
        return found.count == 1 ? found[0].name : nil
    }

    /// The table's row for `name` (any of its names, localized ones included).
    private static func row(_ name: String) -> [String]? {
        let want = norm(name)
        return table.first { row in (row + (localized[row[1]].map { Array($0.values) } ?? [])).contains { norm($0) == want } }
    }

    /// The names the app's Home Screen label can have here (Chinese, English, the device language's), for reading
    /// Spotlight's results: on a Japanese iPhone "Notes" typed lists the app as メモ. Empty when the table does not
    /// know it.
    static func labels(_ name: String, language: String = deviceLanguage) -> [String] {
        guard let row = row(name) else { return [] }
        return [row[0], row[1]] + [own(row[1], language)].compactMap { $0 }
    }

    private static func own(_ en: String, _ language: String) -> String? {
        localized[en]?[language] ?? localized[en]?[String(language.prefix { $0 != "-" })]
    }

    /// At most two other names for `name`'s app, for Spotlight: the device language's name first when the board
    /// can type it (Latin, accents included) or it can be pasted (`paste`: kana, Hangul), else English and Chinese
    /// (Chinese first on a Chinese device).
    static func alternatives(_ name: String, language: String = deviceLanguage, paste: Bool = false) -> [String] {
        let want = norm(name)
        guard let row = row(name) else { return [] }
        let (zh, en) = (row[0], row[1])
        let mine = own(en, language)
        let order = language == "zh" ? [zh, en]
            : mine.map { Accents.typeable($0) || paste ? [$0, en] : [en, zh] } ?? [en, zh]
        var out: [String] = []
        for system in order where norm(system) != want && !out.contains(system) { out.append(system) }
        return out
    }

    /// The iPhone's first language as a key of `localized`: "de", "es" (Spain) or "es-419" (the Americas),
    /// "pt" (Brazil) or "pt-PT", "zh" (Simplified) or "zh-Hant".
    static var deviceLanguage: String { language(Locale.preferredLanguages.first ?? "en") }

    static func language(_ identifier: String) -> String {
        let lang = Locale.Language(identifier: identifier)
        let code = lang.languageCode?.identifier ?? "en"
        let full = Locale.Language(identifier: lang.maximalIdentifier)
        switch code {
        case "zh": return full.script?.identifier == "Hant" ? "zh-Hant" : "zh"
        case "es": return [nil, "ES"].contains(lang.region?.identifier) ? "es" : "es-419"
        case "pt": return lang.region?.identifier == "PT" ? "pt-PT" : "pt"
        default: return code
        }
    }

    static func norm(_ s: String) -> String { Scripts.fold(s) }
}
