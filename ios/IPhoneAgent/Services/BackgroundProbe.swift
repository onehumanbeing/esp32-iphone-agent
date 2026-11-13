import Darwin
import Foundation

/// What woke the main thread while a run was in the background: counts only, summed into one log line a
/// minute (never per frame), so a single device run shows whether the UI keeps working out of sight.
struct BackgroundCounters: Equatable {
    var hintWrites = 0, hintChanges = 0  // Home hint sets, and the ones that changed its text
    var modelNotices = 0                 // the app model's change notices (each re-renders the views observing it)
    var videoUnits = 0, framesDecoded = 0
    var faceTicks = 0                    // the character's animation timeline
    var cpu = 0.0, mainCPU = 0.0         // process and main-thread CPU seconds

    static func - (a: Self, b: Self) -> Self {
        Self(hintWrites: a.hintWrites - b.hintWrites, hintChanges: a.hintChanges - b.hintChanges,
             modelNotices: a.modelNotices - b.modelNotices, videoUnits: a.videoUnits - b.videoUnits,
             framesDecoded: a.framesDecoded - b.framesDecoded, faceTicks: a.faceTicks - b.faceTicks,
             cpu: a.cpu - b.cpu, mainCPU: a.mainCPU - b.mainCPU)
    }
}

/// Rate limit for the background summary: one line per `interval` while active, plus a closing line for a
/// stint of at least `least` seconds when it ends.
struct MinuteSummary {
    let interval: Double
    let least: Double
    private var since: Double?
    private var base = BackgroundCounters()

    init(interval: Double = 60, least: Double = 10) {
        self.interval = interval
        self.least = least
    }

    /// Called on every tick with the running totals; returns a line to log, or nil.
    mutating func tick(_ totals: BackgroundCounters, at t: Double, active: Bool) -> String? {
        guard let start = since else {
            if active { since = t; base = totals }
            return nil
        }
        let span = t - start
        if !active {
            since = nil
            return span >= least ? Self.line(totals - base, seconds: span, closing: true) : nil
        }
        guard span >= interval else { return nil }
        let line = Self.line(totals - base, seconds: span, closing: false)
        since = t
        base = totals
        return line
    }

    static func line(_ d: BackgroundCounters, seconds: Double, closing: Bool) -> String {
        let s = max(seconds, 0.001)
        return String(format: "background %@%.0f s: hint writes %d (changed %d), app model notices %d (%.1f/s), video units %d, frames decoded %d, face ticks %d, CPU %.1f s (%.0f%%), main thread %.1f s (%.0f%%)",
                      closing ? "(ended) " : "", seconds, d.hintWrites, d.hintChanges, d.modelNotices, Double(d.modelNotices) / s,
                      d.videoUnits, d.framesDecoded, d.faceTicks, d.cpu, d.cpu / s * 100, d.mainCPU, d.mainCPU / s * 100)
    }
}

enum ProcessCPU {
    /// User + system CPU seconds of the whole process so far.
    static func seconds() -> Double {
        var u = rusage()
        guard getrusage(RUSAGE_SELF, &u) == 0 else { return 0 }
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    nonisolated(unsafe) private static var mainPort: mach_port_t = 0

    /// User + system CPU seconds of the main thread so far (0 until first called on the main thread).
    static func mainThreadSeconds() -> Double {
        if mainPort == 0 && Thread.isMainThread { mainPort = mach_thread_self() }
        let port = mainPort
        guard port != 0 else { return 0 }
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(port, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.user_time.seconds + info.system_time.seconds)
            + Double(info.user_time.microseconds + info.system_time.microseconds) / 1e6
    }
}

/// Where the run was, kept across a process restart: the next launch says so in its first line.
enum RunMarker {
    private static let key = "runMarker", timeKey = "runMarkerAt"
    nonisolated(unsafe) private static var current: String?

    static func set(_ stage: String) {
        guard stage != current else { return }
        current = stage
        UserDefaults.standard.set(stage, forKey: key)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: timeKey)
    }

    static func clear() {
        guard current != nil || UserDefaults.standard.string(forKey: key) != nil else { return }
        current = nil
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.removeObject(forKey: timeKey)
    }

    /// The previous process's last stage and how long before this launch it was set; read once, then cleared.
    static func takePrevious() -> (stage: String, ago: Double)? {
        guard current == nil, let stage = UserDefaults.standard.string(forKey: key) else { return nil }
        let at = UserDefaults.standard.double(forKey: timeKey)
        clear()
        return (stage, at > 0 ? Date().timeIntervalSince1970 - at : -1)
    }
}
