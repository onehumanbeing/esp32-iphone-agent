import SwiftUI

/// One image inside the agent's files, decoded off the main thread and fitted to the width.
struct LocalImageView: View {
    let url: URL?
    @State private var image: UIImage?
    @State private var missing = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(.rect(cornerRadius: 8))
                    .accessibilityLabel(Text(verbatim: url?.lastPathComponent ?? ""))
            } else if missing {
                Label("Image not on this iPhone", systemImage: "photo")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        guard let url, url.isFileURL, AgentFiles.contains(url) else { missing = true; return }
        let decoded = await Task.detached(priority: .userInitiated) {
            UIImage(contentsOfFile: url.path)?.preparingForDisplay()
        }.value
        image = decoded
        missing = decoded == nil
    }
}
