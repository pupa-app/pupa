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

    /// The brand art masked into Apple's macOS icon grid: a
    /// continuous-curvature superellipse with ~10% transparent inset. Use for
    /// `NSApp.applicationIconImage` — SwiftPM binaries have no asset-catalog
    /// AppIcon, so macOS won't auto-mask; without this the demo Dock icon is a
    /// raw square. Mirrors `scripts/gen-macos-appicon.swift`.
    public static var macDockImage: NSImage? {
        guard let base = nsImage,
              let cg = base.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let ctx = CGContext(data: nil, width: 1024, height: 1024,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let side: CGFloat = 1024, inset = side * 0.10
        let content = CGRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
        ctx.interpolationQuality = .high
        ctx.addPath(squircle(in: content, n: 5))
        ctx.clip()
        ctx.draw(cg, in: content)
        guard let masked = ctx.makeImage() else { return nil }
        return NSImage(cgImage: masked, size: NSSize(width: side, height: side))
    }

    /// Continuous-curvature squircle (Lamé superellipse) centred in `rect`.
    private static func squircle(in rect: CGRect, n: Double) -> CGPath {
        let cx = rect.midX, cy = rect.midY, a = rect.width / 2, b = rect.height / 2
        let path = CGMutablePath()
        let steps = 720
        for i in 0...steps {
            let t = Double(i) / Double(steps) * 2 * .pi
            let ct = cos(t), st = sin(t)
            let x = pow(abs(ct), 2 / n) * (ct < 0 ? -1 : 1) * a
            let y = pow(abs(st), 2 / n) * (st < 0 ? -1 : 1) * b
            let p = CGPoint(x: cx + x, y: cy + y)
            if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }
    #endif
}
