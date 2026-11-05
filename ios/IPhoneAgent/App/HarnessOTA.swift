#if DEBUG
import Foundation

/// `-harness-ota <dir>` (harness/fw.sh, Debug builds only): the Mac copied a firmware build and its manifest to
/// Documents/<dir> over Wi-Fi (devicectl); the app sends it to the board like Update Board does. The Mac can't
/// reach the board itself while the app is connected, so this is how the board gets test builds without a cable.
/// Unlike releases, a harness build may be unsigned and the version the board already runs; the image must
/// still match the manifest's size, SHA-256 and MD5. One result line goes to debug.log: `harness ota: done …`
/// or `harness ota: failed …`.
extension Firmware {
    static func harnessRelease(_ manifest: Data, image: Data, over current: FirmwareVersion) throws -> FirmwareRelease {
        guard let r = try? JSONDecoder().decode(FirmwareRelease.self, from: manifest) else { throw Failure("bad firmware.json") }
        guard matches(image, r) else { throw Failure("the image doesn't match firmware.json") }
        guard r.ver >= current else { throw Failure("\(r.ver) is older than the board's \(current)") }
        return r
    }
}

extension AppModel {
    func harnessOTA(_ dir: String) {
        Task { [weak self] in
            guard let self else { return }
            let result: String
            do { result = "done " + (try await self.runHarnessOTA(dir)) } catch { result = "failed " + error.localizedDescription }
            self.say("harness ota: " + result)
        }
    }

    private func runHarnessOTA(_ dir: String) async throws -> String {
        guard !dir.isEmpty, !dir.hasPrefix("."), !dir.contains("/") else { throw Firmware.Failure("bad folder \(dir)") }
        let manifest = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(dir + "/firmware.json")
        guard let data = try? Data(contentsOf: manifest),
              let url = (try? JSONDecoder().decode(FirmwareRelease.self, from: data)).flatMap({ URL(string: $0.url, relativeTo: manifest) }),
              url.isFileURL, let image = try? Data(contentsOf: url) else { throw Firmware.Failure("no firmware.json and image in Documents/\(dir)") }
        say("harness ota: waiting for the board")
        let end = now() + 60
        while !(board.connected && board.status?.fw != nil) {
            guard now() < end else { throw Firmware.Failure("board not connected in 60 s") }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        let release = try Firmware.harnessRelease(data, image: image, over: firmware.current)
        if let blocker = firmware.blocker { throw Firmware.Failure(blocker) }
        say("harness ota: installing \(release.version) (\(release.sig == nil ? "unsigned" : "signed")) over \(firmware.current)")
        await firmware.installStaged(release, manifest: manifest)
        switch firmware.phase {
        case .done: return "fw \(firmware.current) up \(board.status?.up ?? 0)"
        case .failed(let why): throw Firmware.Failure(why)
        default: throw Firmware.Failure("the update didn't start (\(firmware.phase))")
        }
    }
}
#endif
