#!/usr/bin/env swift
// gen-icon-mark.swift — extract the white Pupa mark from the flat app icon
// as a transparent-background layer for the Icon Composer bundle.
//
// The .icon bundle supplies the red plate as a solid `fill`, so its one layer
// must be the mark alone on transparent. The source PNG is a two-colour flat
// composite; every pixel is (1-t)*red + t*white, so t is recovered by
// projecting onto the red->white axis (all three channels, not just one —
// red only spans 23 levels and would quantise the anti-aliased edges).
// Layer art is full-canvas and mask-free: no squircle, no inset. That is
// gen-macos-appicon.swift's job, for the legacy mac_icon_<px>.png set.
//
// Usage:
//   swift scripts/gen-icon-mark.swift [SOURCE_PNG] [OUTPUT_PNG]
// Defaults:
//   SOURCE_PNG = PupaHost/PupaHost/Assets.xcassets/AppIcon.appiconset/icon_1024.png
//   OUTPUT_PNG = PupaHost/PupaHost/AppIcon.icon/Assets/mark.png

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// --- config -----------------------------------------------------------------
let iconSet = "PupaHost/PupaHost/Assets.xcassets/AppIcon.appiconset"
let defaultSource = "\(iconSet)/icon_1024.png"
let defaultOutput = "PupaHost/PupaHost/AppIcon.icon/Assets/mark.png"
let bg = (r: 232.0, g: 33.0, b: 23.0)      // brand red #E82117, sampled from source
let fg = (r: 255.0, g: 255.0, b: 255.0)    // the mark is pure white
let side = 1024                             // Icon Composer grid

let args = Array(CommandLine.arguments.dropFirst())
let sourcePath = args.first ?? defaultSource
let outputPath = args.count > 1 ? args[1] : defaultOutput

// --- load source ------------------------------------------------------------
guard let srcData = FileManager.default.contents(atPath: sourcePath),
      let source = CGImageSourceCreateWithData(srcData as CFData, nil)
        .flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) })
else {
    FileHandle.standardError.write("error: cannot load source PNG at \(sourcePath)\n".data(using: .utf8)!)
    exit(1)
}

func writePNG(_ image: CGImage, to path: String) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return false }
    CGImageDestinationAddImage(dest, image, nil)
    return CGImageDestinationFinalize(dest)
}

// --- rasterise the source at the target grid --------------------------------
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bytesPerRow = side * 4
var pixels = [UInt8](repeating: 0, count: bytesPerRow * side)

let ok: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
    guard let ctx = CGContext(data: raw.baseAddress, width: side, height: side,
                              bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return false }
    ctx.interpolationQuality = .high
    ctx.draw(source, in: CGRect(x: 0, y: 0, width: side, height: side))
    return true
}
guard ok else {
    FileHandle.standardError.write("error: cannot create bitmap context\n".data(using: .utf8)!)
    exit(1)
}

// --- un-mix: alpha = projection of (p - bg) onto (fg - bg) -------------------
let d = (r: fg.r - bg.r, g: fg.g - bg.g, b: fg.b - bg.b)
let den = d.r * d.r + d.g * d.g + d.b * d.b

for i in stride(from: 0, to: pixels.count, by: 4) {
    let p = (r: Double(pixels[i]), g: Double(pixels[i + 1]), b: Double(pixels[i + 2]))
    let t = ((p.r - bg.r) * d.r + (p.g - bg.g) * d.g + (p.b - bg.b) * d.b) / den
    // Foreground is pure white, so premultiplied R = G = B = A.
    let a = UInt8(max(0, min(1, t)) * 255)
    pixels[i] = a; pixels[i + 1] = a; pixels[i + 2] = a; pixels[i + 3] = a
}

// --- write ------------------------------------------------------------------
try? FileManager.default.createDirectory(
    atPath: (outputPath as NSString).deletingLastPathComponent,
    withIntermediateDirectories: true)

guard let provider = CGDataProvider(data: Data(pixels) as CFData),
      let out = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: bytesPerRow, space: colorSpace,
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: true,
                        intent: .defaultIntent),
      writePNG(out, to: outputPath)
else {
    FileHandle.standardError.write("error: failed to write \(outputPath)\n".data(using: .utf8)!)
    exit(1)
}

print("wrote \(outputPath)")
