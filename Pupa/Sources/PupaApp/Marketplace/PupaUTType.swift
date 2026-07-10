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
    /// apps. This is a permanent wire identifier: the OS maps the `.pupa`
    /// extension to it for tap-to-open, so a `.pupa` exported before this
    /// rename must be re-exported to route again. `.pupa` file *bytes* and the
    /// marketplace catalog are unaffected — the UTType is not embedded in them.
    static var pupaAppBundle: UTType { UTType(exportedAs: "com.pupa-app.app-bundle") }
}
