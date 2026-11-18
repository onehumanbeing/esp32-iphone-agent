import SwiftUI
import UIKit

/// iPad: the keyboard is shared by the apps on screen, and iPadOS reports another app's to this one too (Spotlight's,
/// which a run opens while this app is in the background). SwiftUI kept room for that keyboard after the app came
/// back, so the bottom bar's Start/Stop button sat in the middle of the screen over a gap (iPad Air M3, 2026-11-17
/// trace). Only a keyboard of this app's own (a focused field here) moves the layout; an iPhone is left as it was.
@MainActor final class LocalKeyboard: ObservableObject {
    static let shared = LocalKeyboard()
    /// This app's own keyboard is on screen.
    @Published private(set) var shown = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { note in
            let local = note.userInfo?[UIResponder.keyboardIsLocalUserInfoKey] as? Bool ?? true
            MainActor.assumeIsolated { LocalKeyboard.shared.update(local) }
        })
        for name in [UIResponder.keyboardWillHideNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { LocalKeyboard.shared.update(false) }
            })
        }
    }

    private func update(_ local: Bool) { if shown != local { shown = local } }

    /// Whether the layout may leave room for the keyboard now. iPhone: always (its keyboard is always its own).
    nonisolated static func avoids(pad: Bool, localShown: Bool) -> Bool { !pad || localShown }
}

private struct ForeignKeyboardIgnored: ViewModifier {
    @ObservedObject private var keyboard = LocalKeyboard.shared

    func body(content: Content) -> some View {
        // one view either way (a branch would rebuild the tabs, and a focused field lose its keyboard)
        content.ignoresSafeArea(LocalKeyboard.avoids(pad: DeviceKind.isPad, localShown: keyboard.shown) ? [] : .keyboard,
                                edges: .bottom)
    }
}

extension View {
    /// iPad: no room kept for another app's keyboard (LocalKeyboard). An iPhone's layout is unchanged.
    func ignoringForeignKeyboard() -> some View { modifier(ForeignKeyboardIgnored()) }
}
