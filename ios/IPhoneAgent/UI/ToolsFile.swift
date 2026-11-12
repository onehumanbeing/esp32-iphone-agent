import CoreTransferable
import UniformTypeIdentifiers

/// The imported tools as handsy-tools.json for the share sheet (Tools › Export Tools…). No keys in it.
struct ToolsFile: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { $0.data }
            .suggestedFileName("handsy-tools.json")
    }
}
