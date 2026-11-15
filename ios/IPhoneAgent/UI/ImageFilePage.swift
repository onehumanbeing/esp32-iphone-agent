import SwiftUI

/// One image from the agent directory, fitted to the space it is given.
struct ImageFilePage: View {
    let file: URL

    var body: some View {
        VStack(spacing: Space.l) {
            if let image = UIImage(contentsOfFile: file.path) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(.rect(cornerRadius: 12))
                    .padding(.horizontal, Space.l)
                    .accessibilityLabel(Text(verbatim: file.lastPathComponent))
            } else {
                ContentUnavailableView {
                    Label("Can't show this image", systemImage: "photo")
                } description: {
                    Text("You can still share the file.")
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.grouped)
        .navigationTitle(Text(verbatim: file.lastPathComponent))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: file) { Label("Share", systemImage: "square.and.arrow.up") }
                    .labelStyle(.iconOnly)
            }
        }
    }
}
