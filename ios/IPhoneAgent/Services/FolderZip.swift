import Foundation

/// A folder packed as one .zip to share, by the system (NSFileCoordinator's `forUploading`), with no zip library.
enum FolderZip {
    /// A .zip of `folder` in the temporary directory, or nil when it could not be made.
    static func make(_ folder: URL) -> URL? {
        var made: URL?
        var failure: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &failure) { zipped in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(folder.lastPathComponent + ".zip")
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: zipped, to: dest)) != nil { made = dest }
        }
        return failure == nil ? made : nil
    }
}
