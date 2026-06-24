#if os(iOS)
import UIKit
#elseif os(macOS)
import Foundation
#endif

/// This device's human-readable name, used as the pairing label and on the
/// Account screen. One place so the `#if os` branch isn't duplicated.
public enum DeviceInfo {
    public static var localName: String {
        #if os(iOS)
        return UIDevice.current.name
        #elseif os(macOS)
        return Host.current().localizedName ?? "Mac"
        #else
        return "Pupa"
        #endif
    }
}
