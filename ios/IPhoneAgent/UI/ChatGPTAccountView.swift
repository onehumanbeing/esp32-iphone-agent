import SafariServices
import SwiftUI

/// Settings › Model with ChatGPT picked: in place of the API key, the sign-in button, or the account and its
/// usage. Rows for ProviderFields' stack (dividers between them).
struct ChatGPTAccountRows: View {
    @ObservedObject private var auth = ChatGPTAuth.shared

    var body: some View {
        if let account = auth.account {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: Self.masked(account.email) ?? "ChatGPT")
                    Text("ChatGPT \(account.plan?.capitalized ?? "") · signed in").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Sign Out", role: .destructive) { auth.signOut() }.buttonStyle(.borderless)
            }
            .frame(minHeight: 44).padding(.vertical, Space.xs)
            if auth.limits.primary != nil || auth.limits.secondary != nil {
                Divider()
                VStack(spacing: Space.s) {
                    if let w = auth.limits.primary { UsageBar(title: "5-hour limit", window: w) }
                    if let w = auth.limits.secondary { UsageBar(title: "Weekly limit", window: w) }
                }
                .padding(.vertical, Space.s)
            }
        } else {
            VStack(alignment: .leading, spacing: Space.s) {
                Button { ChatGPTSignInPresenter.shared.presented = true } label: {
                    Text("Sign in with ChatGPT").font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                Text("Runs count against your ChatGPT plan's usage limits, the same allowance Codex uses. Plus or Pro works best.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.vertical, Space.s)
        }
    }

    /// a•••@example.com: enough to tell accounts apart on a shared screen.
    static func masked(_ email: String?) -> String? {
        guard let email, let at = email.firstIndex(of: "@"), at > email.startIndex else { return email }
        return String(email[email.startIndex]) + "•••" + email[at...]
    }
}

private struct UsageBar: View {
    let title: LocalizedStringKey
    let window: ChatGPTAuth.Window

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text(title).font(.subheadline)
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))% used").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }
            ProgressView(value: min(max(window.usedPercent, 0), 100), total: 100)
                .tint(window.usedPercent >= 90 ? Palette.warning : Palette.accent)
            if let reset = window.resetsAt {
                Text("Resets \(reset.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Whether the sign-in sheet is up. Kept out of ChatGPTAccountRows (#965): a sheet presented from a Form row was
/// rebuilt mid sign-in when the row was hosted again, restarting the attempt and closing the browser page.
@MainActor final class ChatGPTSignInPresenter: ObservableObject {
    static let shared = ChatGPTSignInPresenter()
    @Published var presented = false
}

extension View {
    /// Presents the ChatGPT sign-in sheet. Attach to a stable container (a NavigationStack, a Form), never to a row,
    /// and to one container per screen: `enabled: false` where a sheet above hosts it instead.
    @ViewBuilder func chatGPTSignInHost(enabled: Bool = true) -> some View {
        if enabled { modifier(ChatGPTSignInHost()) } else { self }
    }
}

private struct ChatGPTSignInHost: ViewModifier {
    @ObservedObject private var presenter = ChatGPTSignInPresenter.shared

    func body(content: Content) -> some View {
        content.sheet(isPresented: $presenter.presented) { ChatGPTSignInSheet() }
    }
}

/// The device code: copied with one tap, entered on OpenAI's page in an in-app Safari view; the sheet closes on its own
/// once the sign-in goes through.
struct ChatGPTSignInSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var code: ChatGPTAuth.DeviceCode?
    @State private var error: String?
    @State private var showingPage = false
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: Space.l) {
                if let code {
                    Text("Enter this code on OpenAI's page. Tap below to copy it and open the page.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Text(verbatim: code.userCode)
                        .font(.system(size: 34, weight: .semibold, design: .monospaced)).tracking(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity).padding(.vertical, Space.l)
                        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 12))
                    Button {
                        UIPasteboard.general.string = code.userCode
                        showingPage = true
                    } label: {
                        Text("Copy and Open Sign-in Page").font(.body.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    HStack(spacing: Space.s) {
                        ProgressView()
                        Text("Waiting for sign-in")
                    }
                    .font(.footnote).foregroundStyle(.secondary)
                } else if let error {
                    Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.circle") }
                        .foregroundStyle(.secondary)
                    Button("Try Again") { self.error = nil; attempt += 1 }.buttonStyle(.bordered)
                } else {
                    ProgressView()
                }
                Text("Only enter a code that you started here. If a website or another person gave you a code, cancel.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Spacer()
            }
            .padding(Space.l)
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Sign in with ChatGPT")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $showingPage) { if let code { SafariView(url: code.verificationURL).ignoresSafeArea() } }
            .task(id: attempt) { await signIn() }  // cancelled when the sheet closes
        }
        .presentationDetents([.medium, .large])
    }

    private func signIn() async {
        code = nil
        do {
            let next = try await ChatGPTAuth.shared.requestDeviceCode()
            code = next
            try await ChatGPTAuth.shared.complete(next)
            showingPage = false
            dismiss()
        } catch is CancellationError {
        } catch {
            code = nil
            self.error = error.localizedDescription
            DebugLog.write("chatgpt: sign-in failed: \(error.localizedDescription)")
        }
    }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
