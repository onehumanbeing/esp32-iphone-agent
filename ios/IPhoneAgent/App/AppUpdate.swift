import SwiftUI

/// A newer Manina AI on the App Store: asked once a day with a sheet (Update / Later), then a banner on Home that
/// stays until the app is updated, the way old board firmware is (Henry 2026-11-18: one app version goes with one
/// firmware; users who don't update are reminded firmly, never locked out). The board firmware's `min_app` sends
/// here too: a firmware this app is too old for is not offered, the app update is.
@MainActor
final class AppUpdate: ObservableObject {
    static let shared = AppUpdate()
    static let appID = "6822927873"

    @Published private(set) var latest: FirmwareVersion?  // the App Store's version (same a.b.c form)
    @Published private(set) var storeURL = URL(string: "https://apps.apple.com/app/id\(appID)")!
    @Published var presented = false
    private var checkedAt = -Double.infinity
    private static let askedKey = "appUpdateAskedDay"

    static var current: FirmwareVersion {
        FirmwareVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") ?? FirmwareVersion([0])
    }

    /// Only an App Store install checks: TestFlight and local builds update another way.
    static var fromStore: Bool {
        #if DEBUG
        return false
        #else
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "receipt" && !MockMode.on
        #endif
    }

    /// The App Store has a newer version than this one.
    var outdated: Bool { latest.map { $0 > Self.current } ?? false }

    /// At most once an hour; then the sheet if it has not been shown today.
    func check() async {
        guard Self.fromStore, Date().timeIntervalSince1970 - checkedAt >= 3600 else { return ask() }
        checkedAt = Date().timeIntervalSince1970
        let region = Locale.current.region?.identifier.lowercased() ?? "us"
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(Self.appID)&country=\(region)"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let found = Self.parse(data) else { return }
        latest = found.version
        if let page = found.url { storeURL = page }
        DebugLog.write("app update: store \(found.version), this \(Self.current)")
        ask()
    }

    /// The version and page in an iTunes lookup reply.
    nonisolated static func parse(_ data: Data) -> (version: FirmwareVersion, url: URL?)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["results"] as? [[String: Any]])?.first,
              let version = (first["version"] as? String).flatMap(FirmwareVersion.init) else { return nil }
        return (version, (first["trackViewUrl"] as? String).flatMap(URL.init(string:)))
    }

    func ask() {
        guard outdated, !presented else { return }
        let today = String(MemoryFiles.stamp(Date()).prefix(10))
        guard UserDefaults.standard.string(forKey: Self.askedKey) != today else { return }
        UserDefaults.standard.set(today, forKey: Self.askedKey)
        presented = true
    }

    func open() { UIApplication.shared.open(storeURL) }
}

/// Home: the sheet once a day, on launch and on coming back to the app.
struct AppUpdateGate: ViewModifier {
    @ObservedObject var update = AppUpdate.shared
    @Environment(\.scenePhase) private var scene

    func body(content: Content) -> some View {
        content
            .task { await update.check() }
            .onChange(of: scene) { _, phase in if phase == .active { Task { await update.check() } } }
            .sheet(isPresented: $update.presented) { AppUpdateSheet(update: update) }
    }
}

struct AppUpdateSheet: View {
    @ObservedObject var update: AppUpdate
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Space.l) {
            Image(systemName: "arrow.down.app.fill").font(.system(size: 44)).foregroundStyle(Color.accentColor)
            Text("Update \(AppName.current)").font(.title2.bold())
            Text("Version \(update.latest?.description ?? "") is on the App Store. Updating keeps the app and the board firmware in step; older versions may not work with new boards.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button { update.open(); dismiss() } label: { Text("Update").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Button("Later") { dismiss() }
        }
        .padding(Space.xl)
        .presentationDetents([.medium])
    }
}

/// Above the face on Home while a newer app is out, or the board's new firmware needs a newer app. No ×.
struct AppUpdateBanner: View {
    @ObservedObject var update = AppUpdate.shared
    @ObservedObject var firmware: FirmwareUpdater

    var body: some View {
        if update.outdated || firmware.needsNewerApp {
            Button(action: update.open) {
                HStack(spacing: Space.s) {
                    Label(firmware.needsNewerApp ? "New board firmware needs the latest app" : "A new version of the app is out",
                          systemImage: "arrow.down.app.fill")
                    Text("Update").bold()
                }
                .font(.footnote.weight(.medium))
            }
            .foregroundStyle(.orange)
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.s)
            .background(Color.orange.opacity(0.15), in: Capsule())
        }
    }
}
