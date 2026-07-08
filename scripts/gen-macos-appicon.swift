#!/usr/bin/env swift
// gen-macos-appicon.swift — regenerate the mac-idiom AppIcon PNGs.
//
// macOS does NOT auto-mask app icons (unlike iOS). The icon must be drawn
// inside Apple's macOS icon grid: a continuous-curvature rounded rect
// (superellipse) with ~10% transparent padding. This script masks the
// full-bleed source art into that shape and emits mac_icon_<px>.png for
// every mac-idiom size. iOS/universal icon_1024.png is left untouched.
//
// Usage:
//   swift scripts/gen-macos-appicon.swift [SOURCE_PNG] [OUTPUT_DIR]
// Defaults:
//   SOURCE_PNG = PupaHost/PupaHost/Assets.xcassets/AppIcon.appiconset/icon_1024.png
//   OUTPUT_DIR = dirname(SOURCE_PNG)

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// --- config -----------------------------------------------------------------
let iconSet = "PupaHost/PupaHost/Assets.xcassets/AppIcon.appiconset"
let defaultSource = "\(iconSet)/icon_1024.png"
let sizes = [16, 32, 64, 128, 256, 512, 1024]   // mac-idiom pixel sizes
let contentFraction = 0.80                        // art fills inner 80% of tile
let superellipseN = 5.0                           // Apple macOS squircle exponent

let args = Array(CommandLine.arguments.dropFirst())
let sourcePath = args.first ?? defaultSource
let outputDir = args.count > 1 ? args[1] : (sourcePath as NSString).deletingLastPathComponent

// --- load source ------------------------------------------------------------
guard let srcData = FileManager.default.contents(atPath: sourcePath),
      let srcProvider = CGDataProvider(data: srcData as CFData),
      let source = CGImage(pngDataProviderSource: srcProvider,
                           decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        ?? CGImageSourceCreateWithData(srcData as CFData, nil)
            .flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) })
else {
    FileHandle.standardError.write("error: cannot load source PNG at \(sourcePath)\n".data(using: .utf8)!)
    exit(1)
}

// Continuous-curvature squircle (Lamé superellipse) centered in `rect`.
func squirclePath(in rect: CGRect, n: Double) -> CGPath {
    let cx = rect.midX, cy = rect.midY
    let a = rect.width / 2, b = rect.height / 2
    let path = CGMutablePath()
    let steps = 720
    for i in 0...steps {
        let t = Double(i) / Double(steps) * 2 * Double.pi
        let ct = cos(t), st = sin(t)
        // |x/a|^n + |y/b|^n = 1  ->  parametric with sign-preserving power
        let x = pow(abs(ct), 2.0 / n) * (ct < 0 ? -1 : 1) * a
        let y = pow(abs(st), 2.0 / n) * (st < 0 ? -1 : 1) * b
        let p = CGPoint(x: cx + x, y: cy + y)
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath()
    return path
}

func writePNG(_ image: CGImage, to path: String) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

let colorSpace = CGColorSpaceCreateDeviceRGB()

for size in sizes {
    let s = CGFloat(size)
    guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                              bytesPerRow: 0, space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { continue }
    ctx.interpolationQuality = .high
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    let inset = s * (1 - contentFraction) / 2
    let contentRect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)

    ctx.addPath(squirclePath(in: contentRect, n: superellipseN))
    ctx.clip()
    ctx.draw(source, in: contentRect)

    guard let out = ctx.makeImage() else { continue }
    let outPath = "\(outputDir)/mac_icon_\(size).png"
    if writePNG(out, to: outPath) {
        print("wrote \(outPath)")
    } else {
        FileHandle.standardError.write("error: failed to write \(outPath)\n".data(using: .utf8)!)
        exit(1)
    }
}

print("done — remember: Contents.json mac entries must point at mac_icon_<px>.png")
