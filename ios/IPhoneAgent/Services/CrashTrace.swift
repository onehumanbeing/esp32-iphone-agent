import Darwin
import Foundation
import MachO

/// On a fatal signal, appends the raw call stack to Documents/crash-trace.txt, then lets the crash go on (the
/// system report and MetricKit still get it). iOS stops writing reports after a few crashes a day; this file
/// is the stack for a crash loop (2026-10-19). Symbolicate with ios/scripts/symbolicate_crash.py.
enum CrashTrace {
    nonisolated(unsafe) private static var fd: Int32 = -1

    static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("crash-trace.txt")

    static func install() {
        fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let base = _dyld_get_image_header(0).map { UInt(bitPattern: $0) } ?? 0
        header = Array("=== build \(build), image base 0x\(String(base, radix: 16)), launched \(Date())\n".utf8)
        for sig in [SIGTRAP, SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { sig in
                CrashTrace.header.withUnsafeBytes { _ = write(CrashTrace.fd, $0.baseAddress, $0.count) }
                var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
                let n = backtrace(&frames, 64)
                backtrace_symbols_fd(&frames, n, CrashTrace.fd)
                signal(sig, SIG_DFL)
                raise(sig)
            }
            sigaction(sig, &action, nil)
        }
    }

    nonisolated(unsafe) private static var header: [UInt8] = []
}
