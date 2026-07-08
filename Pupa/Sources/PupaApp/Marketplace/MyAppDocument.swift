import SwiftUI
import UniformTypeIdentifiers

/// Thin `FileDocument` wrapper around raw bundle bytes, for SwiftUI's
/// `.fileImporter` on iOS + macOS.
///
/// Writes the branded `.pupaAppBundle` type (`.pupa`, declared in the
/// PupaHost Info.plist); reads both it and legacy `.json` exports. A bundle
/// *is* JSON, so the importer still validates via the header `format` magic,
/// not the extension. See docs/marketplace.md.
struct MyAppDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pupaAppBundle, .json] }
    static var writableContentTypes: [UTType] { [.pupaAppBundle] }

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
