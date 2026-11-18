import SwiftUI

extension ToolbarContent {
    /// No glass capsule behind this item (iOS 26 puts one behind every toolbar button). A labelled icon reads
    /// cleaner on the bare bar (Henry, 2026-11-16). Earlier iOS has no capsule.
    @ToolbarContentBuilder func plainBackground() -> some ToolbarContent {
        if #available(iOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}
