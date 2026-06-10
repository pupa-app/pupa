import SwiftUI
import UniformTypeIdentifiers

/// Thin `FileDocument` wrapper around raw bundle bytes, for SwiftUI's
/// `.fileExporter` / `.fileImporter` on iOS + macOS.
///
/// Content type is `.json`: a bundle *is* a JSON document, and the importer
/// validates it via the header `format` magic, not the file extension. A bare
/// `.pupaapp` extension needs a declared exported UTType (PupaHost Info.plist) —
/// an in-code dynamic type names exports but the OS won't recognize it on
/// import, greying the file out. Deferred; see docs/marketplace.md and #52.
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
