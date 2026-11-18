import Darwin
import Foundation
import MachO

/// What the main thread runs while it is stuck: MainLag samples its stack every 20 ms once a probe has waited over
/// 0.25 s, and logs the app's busiest frames when it answers. Henry 2026-11-19 (Gaode): the main thread waited 1-2 s
/// every 1.5 s for minutes, board acks took 1.2-3 s, and the log could only say "during look"; a profiler needs the
/// phone on the Mac's cable, where the board cannot be. Frames are logged as symbol (dladdr) or image+offset, so a
/// stripped build can still be read with `atos -o <binary> -l <load address>`.
final class MainStall: @unchecked Sendable {  // used on MainLag's queue only
    static let depth = 48
    private var thread: thread_act_t = 0
    private var stackLow: UInt = 0, stackHigh: UInt = 0
    private let buffer = UnsafeMutablePointer<UInt>.allocate(capacity: depth)
    private var counts: [UInt: Int] = [:]  // first app frame -> samples
    private var stacks: [UInt: [UInt]] = [:]  // one stack per first app frame
    private(set) var samples = 0
    private let app: (low: UInt, high: UInt)

    /// Call on the main thread.
    init() {
        thread = mach_thread_self()
        let top = UInt(bitPattern: pthread_get_stackaddr_np(pthread_self()))
        (stackHigh, stackLow) = (top, top - UInt(pthread_get_stacksize_np(pthread_self())))
        app = Self.appRange()
    }

    /// One sample of the main thread's stack (suspended for a few microseconds; nothing here allocates while it is).
    func sample() {
        guard thread != 0, thread_suspend(thread) == KERN_SUCCESS else { return }
        var n = 0
        var state = arm_thread_state64_t()
        var count = mach_msg_type_number_t(MemoryLayout<arm_thread_state64_t>.size / MemoryLayout<UInt32>.size)
        let got = withUnsafeMutablePointer(to: &state) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_get_state(thread, ARM_THREAD_STATE64, $0, &count)
            }
        }
        if got == KERN_SUCCESS {
            buffer[0] = Self.strip(UInt(state.__pc)); n = 1
            buffer[1] = Self.strip(UInt(state.__lr)); n = 2
            var fp = Self.strip(UInt(state.__fp))
            while n < Self.depth, fp >= stackLow, fp + 16 <= stackHigh, fp % 8 == 0 {
                let frame = UnsafePointer<UInt>(bitPattern: fp)!
                let ret = Self.strip(frame[1]), next = Self.strip(frame[0])
                if ret == 0 { break }
                buffer[n] = ret; n += 1
                if next <= fp { break }
                fp = next
            }
        }
        thread_resume(thread)
        samples += 1
        let stack = Array(UnsafeBufferPointer(start: buffer, count: n))
        guard let top = stack.first(where: { $0 >= app.low && $0 < app.high }) else { counts[0, default: 0] += 1; return }
        counts[top, default: 0] += 1
        if stacks[top] == nil { stacks[top] = stack }
    }

    /// The stall's line (nil when nothing was sampled), and a reset for the next one.
    func report(lag: Double) -> String? {
        defer { counts = [:]; stacks = [:]; samples = 0 }
        guard samples > 0 else { return nil }
        let top = counts.sorted { $0.value > $1.value }.prefix(3)
        var parts = top.map { "\(Int((Double($0.value) / Double(samples) * 100).rounded()))% \($0.key == 0 ? "system only" : Self.name($0.key))" }
        if let first = top.first, first.key != 0, let stack = stacks[first.key] {
            let callers = stack.filter { $0 >= app.low && $0 < app.high }.prefix(6).dropFirst().map(Self.name)
            if !callers.isEmpty { parts.append("via " + callers.joined(separator: " < ")) }
        }
        return String(format: "main stall %.0f ms, %d samples: ", lag * 1000, samples) + parts.joined(separator: "; ")
    }

    private static func strip(_ p: UInt) -> UInt { p & 0x0000_000F_FFFF_FFFF }  // pointer-auth bits off

    static func name(_ address: UInt) -> String {
        var info = Dl_info()
        guard dladdr(UnsafeRawPointer(bitPattern: address), &info) != 0 else { return String(format: "0x%lx", address) }
        let image = info.dli_fname.map { (String(cString: $0) as NSString).lastPathComponent } ?? "?"
        let base = UInt(bitPattern: info.dli_fbase)
        if let s = info.dli_sname, info.dli_saddr != nil {
            let raw = String(cString: s)
            let name = demangle(raw) ?? raw
            return "\(String(name.prefix(90)))+\(address - UInt(bitPattern: info.dli_saddr))"
        }
        return String(format: "%@+0x%lx", image, address - base)
    }

    private static func demangle(_ s: String) -> String? {
        typealias Fn = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutablePointer<CChar>?, UnsafeMutablePointer<Int>?, UInt32) -> UnsafeMutablePointer<CChar>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_demangle") else { return nil }
        let fn = unsafeBitCast(sym, to: Fn.self)
        guard let out = s.withCString({ fn($0, strlen($0), nil, nil, 0) }) else { return nil }
        defer { free(out) }
        return String(cString: out)
    }

    /// Address range of the app's own code: the main executable and, in Debug, its .debug.dylib.
    private static func appRange() -> (UInt, UInt) {
        var low = UInt.max, high: UInt = 0
        let exe = (Bundle.main.executablePath as NSString?)?.lastPathComponent ?? "IPhoneAgent"
        for i in 0..<_dyld_image_count() {
            guard let cname = _dyld_get_image_name(i), let header = _dyld_get_image_header(i) else { continue }
            let file = (String(cString: cname) as NSString).lastPathComponent
            guard file == exe || file == exe + ".debug.dylib" else { continue }
            let base = UInt(bitPattern: header)
            low = min(low, base); high = max(high, base + textSize(header))
        }
        return low == .max ? (0, 0) : (low, high)
    }

    private static func textSize(_ header: UnsafePointer<mach_header>) -> UInt {
        var cmd = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let lc = cmd.load(as: load_command.self)
            if lc.cmd == LC_SEGMENT_64 {
                let seg = cmd.load(as: segment_command_64.self)
                if withUnsafeBytes(of: seg.segname, { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }) == "__TEXT" {
                    return UInt(seg.vmsize)
                }
            }
            cmd = cmd.advanced(by: Int(lc.cmdsize))
        }
        return 0
    }
}
