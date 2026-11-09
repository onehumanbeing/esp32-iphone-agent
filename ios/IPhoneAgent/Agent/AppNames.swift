import Foundation

/// What people call an app versus what the Home Screen calls it: "闹钟" is 时钟 on a Chinese iPhone and Clock on
/// an English one, and Spotlight finds neither from "闹钟". `open` tries these when the name itself is not found.
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
    ]

    /// The system names to try for `name` (Chinese first, then English), never `name` itself; empty when the
    /// table does not know it.
    static func alternatives(_ name: String) -> [String] {
        let want = norm(name)
        guard let row = table.first(where: { $0.contains { norm($0) == want } }) else { return [] }
        var out: [String] = []
        for system in row.prefix(2) where norm(system) != want && !out.contains(system) { out.append(system) }
        return out
    }

    static func norm(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }
}
