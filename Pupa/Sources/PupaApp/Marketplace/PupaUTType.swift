import UniformTypeIdentifiers

extension UTType {
    /// The exported `.pupaapp` bundle type, declared in the PupaHost
    /// Info.plist (`com.pupa.app-bundle`, conforms to `public.json`). Used by
    /// the exporter/share sheet and the file importer so a bundle travels with
    /// a branded extension and received files open straight into Pupa.
    static var pupaAppBundle: UTType { UTType(exportedAs: "com.pupa.app-bundle") }
}
