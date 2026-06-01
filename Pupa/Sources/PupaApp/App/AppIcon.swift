import SwiftUI

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// The Pupa brand icon, bundled as a resource of the `PupaApp`
/// library so it can be rendered inside the app (sidebar header) and reused
/// by the macOS executable to set `NSApp.applicationIconImage`.
public enum AppIcon {
    private static let resourceName = "AppIcon"

    public static var swiftUIImage: Image? {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "png") else {
            return nil
        }
        #if canImport(AppKit)
        guard let ns = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: ns)
        #elseif canImport(UIKit)
        guard let ui = UIImage(contentsOfFile: url.path) else { return nil }
        return Image(uiImage: ui)
        #else
        return nil
        #endif
    }

    #if canImport(AppKit)
    public static var nsImage: NSImage? {
        Bundle.module.url(forResource: resourceName, withExtension: "png")
            .flatMap { NSImage(contentsOf: $0) }
    }
    #endif
}
