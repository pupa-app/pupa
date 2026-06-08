import SwiftUI
import UniformTypeIdentifiers

/// Thin `FileDocument` wrapper around raw bundle bytes, for SwiftUI's
/// `.fileExporter` / `.fileImporter` on iOS + macOS.
///
/// Content type is `.json`: a `.pupaapp` bundle *is* a JSON document, and the
/// importer validates it via the header `format` magic, not the file
/// extension. (A dedicated exported UTType would add tap-to-open at the cost
/// of a PupaHost Info.plist declaration — deferred; see docs/marketplace.md.)
struct MyAppDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
