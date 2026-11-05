import SwiftUI

/// Live metrics and the built-in tests (BLE bench, snap latency, LLM ping, background run), plus trace export.
struct DiagnosticsView: View {
    @ObservedObject var app: AppModel
    @ObservedObject var metrics: Metrics
    @ObservedObject var board: BoardLink
    @ObservedObject var feed: VideoFeed
    @State private var busy = false
    @State private var shareURL: URL?

    var body: some View {
        List {
            SwiftUI.Section("Tests") {
                test("BLE bench (256 KB)", "speedometer") { await app.bench() }
                test("Snap latency", "camera.viewfinder") { await app.snapTest() }
                test("LLM ping", "bolt") { await app.pingLLM() }
                test("Background test (10 min)", "moon.zzz") { await app.backgroundTest() }
                Button { export() } label: { Label("Export traces", systemImage: "square.and.arrow.up") }
            }
            SwiftUI.Section("BLE") {
                row("App-side video kbps", f(metrics.bleKbps))
                row("Board BLE kbps", f(board.status?.ble?.kbps))
                row("Bench kbps", f(metrics.benchKbps))
                row("MTU (app / board)", "\(metrics.mtu) / \(board.status?.ble?.mtu.map(String.init) ?? "–")")
                row("PHY", board.status?.ble?.phy.map { "\($0)M" } ?? "–")
                row("Drops (app / board)", "\(metrics.drops) / \(board.status?.ble?.drop.map(String.init) ?? "–")")
                row("Status age", String(format: "%.1f s", metrics.statusAge))
            }
            SwiftUI.Section("Video") {
                row("Path", board.status?.udp?.n == 1 ? "Wi-Fi" : "BLE")
                row("Board Wi-Fi kbps", f(board.status?.udp?.kbps))
                row("Wi-Fi resends / drops (board)", "\(board.status?.udp?.nack.map(String.init) ?? "–") / \(board.status?.udp?.drop.map(String.init) ?? "–")")
                row("AirPlay kbps", f(board.status?.kbps))
                row("AirPlay fps", f(board.status?.fps, "%.1f"))
                row("IDR interval (board / app)", "\(board.status?.idr.map { "\($0) ms" } ?? "–") / \(f(metrics.idrIntervalMs)) ms")
                row("GOP buffered", board.status?.gop.map { "\($0 / 1024) KB" } ?? "–")
                row("Resolution", board.status.map { "\($0.w ?? 0) x \($0.h ?? 0)" } ?? "–")
                row("Decoded fps", f(metrics.fps, "%.1f"))
                row("Decode", f(metrics.decodeMs, "%.1f") + " ms")
                row("Snap -> decoded", f(metrics.snapMs) + " ms")
                row("Decode errors (bg)", "\(metrics.decodeErrors) (\(metrics.backgroundDecodeErrors))")
                if !feed.note.isEmpty { Text(feed.note).font(.caption) }
            }
            SwiftUI.Section("Agent") {
                row("LLM first token / total", "\(f(metrics.llmFirstMs)) / \(f(metrics.llmTotalMs)) ms")
                row("LLM ping", f(metrics.llmPingMs) + " ms")
                if let s = metrics.steps.last {
                    row("Last step frame / LLM / HID", "\(f(s.frameMs)) / \(f(s.llmMs)) / \(f(s.hidMs)) ms")
                }
                ForEach(metrics.hidMs.keys.sorted(), id: \.self) { k in row("HID \(k)", f(metrics.hidMs[k]) + " ms") }
            }
            SwiftUI.Section("Background") {
                row("Alive in background", String(format: "%.0f s", metrics.backgroundAlive))
                row("Suspensions", "\(metrics.suspensions)")
            }
            SwiftUI.Section("Board") {
                row("Uptime", board.status?.up.map { "\($0 / 1000) s" } ?? "–")
                row("Reset reason", board.status?.rst ?? "–")
                row("Heap", board.status?.heap.map { "\($0 / 1024) KB" } ?? "–")
                row("PSRAM", board.status?.psram.map { "\($0 / 1024) KB" } ?? "–")
                row("USB", board.status?.usb ?? "–")
                if board.status?.isWirelessHID == true { row("Bluetooth HID", board.status?.hid ?? "–") }
                row("Network", "\(board.status?.net ?? "–") \(board.status?.ip ?? "")")
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $shareURL) { ShareSheet(items: [$0]) }
    }

    private func test(_ title: LocalizedStringKey, _ symbol: String, _ run: @escaping () async -> Void) -> some View {
        Button {
            busy = true
            Haptics.tick()
            Task { await run(); busy = false }
        } label: {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if busy { ProgressView() }
            }
        }
        .disabled(busy)
    }

    private func export() {
        do { shareURL = try TraceStore.zip(app.traces.root) } catch { app.say("export: \(error.localizedDescription)") }
    }

    private func row(_ k: LocalizedStringKey, _ v: String) -> some View { ValueRow(title: k, value: v) }

    private func f(_ v: Double?, _ format: String = "%.0f") -> String { v.map { String(format: format, $0) } ?? "–" }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
