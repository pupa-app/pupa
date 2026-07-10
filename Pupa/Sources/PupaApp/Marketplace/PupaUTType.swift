import UniformTypeIdentifiers

extension UTType {
    /// The exported `.pupa` bundle type, declared in the PupaHost
    /// Info.plist (`com.pupa-app.app-bundle`, conforms to `public.data`). Used
    /// by the exporter/share sheet and the file importer so a bundle travels
    /// with a branded extension and received files open straight into Pupa.
    ///
    /// Uses the owned-domain reverse-DNS prefix `com.pupa-app`, matching the
    /// app bundle-id namespace (`com.pupa-app.*`). Target-neutral (no `.ios` /
    /// `.client`) because the same document type is shared by the iOS and macOS
    /// apps. Renamed from the earlier `com.pupa.app-bundle`, which the
    /// Info.plist keeps as a legacy imported/accepted type so files tagged with
    /// the old UTI still open in Pupa (non-breaking). `.pupa` file *bytes* and
    /// the marketplace catalog are unaffected — the UTType is not embedded.
    static var pupaAppBundle: UTType { UTType(exportedAs: "com.pupa-app.app-bundle") }
}
