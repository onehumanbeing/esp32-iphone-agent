import UIKit

/// iPhone or iPad. Everything that behaves differently on an iPad asks here, so an iPhone takes the code paths it
/// always took. Settable for tests.
enum DeviceKind {
    static var isPad = UIDevice.current.userInterfaceIdiom == .pad

    /// The device's name for the models and the app's own prompts ("iPhone" / "iPad").
    static var name: String { isPad ? "iPad" : "iPhone" }
}
