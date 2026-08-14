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

    /// Running on a Mac — native, or the iOS build on Apple silicon
    /// ("Designed for iPad" / Catalyst), where `os(macOS)` is *false*.
    /// Runtime, not `#if`, because the shipping Mac app is the iOS binary.
    public static var isMac: Bool {
        #if os(macOS)
        return true
        #elseif os(iOS)
        return ProcessInfo.processInfo.isiOSAppOnMac
            || ProcessInfo.processInfo.isMacCatalystApp
        #else
        return false
        #endif
    }
}
