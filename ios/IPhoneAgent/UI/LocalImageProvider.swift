import MarkdownUI
import SwiftUI

/// The images of an agent result (`![](page-01.jpg)` next to its README), read from this iPhone and never fetched:
/// a result stays local, so a link to the web shows as a placeholder.
struct LocalImageProvider: ImageProvider {
    func makeImage(url: URL?) -> some View {
        LocalImageView(url: url)
    }
}
