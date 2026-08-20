import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Prepares user-attached images for sending to the agent: re-encodes as JPEG,
/// downscaled so the long edge fits within Bedrock's per-image input limits
/// (~3.75 MP / 5 MB after base64 inflation). Cross-platform — built on
/// ImageIO so it compiles on both iOS and macOS without UIKit/AppKit.
enum ImagePreparer {
    /// Maximum long-edge in pixels for a prepared image. Keeps the pixel count
    /// under ~3.75 MP for any aspect ratio while staying inside Bedrock's
    /// 1568-px guidance for Anthropic vision models on Bedrock.
    static let maxLongEdge: CGFloat = 1568

    /// JPEG quality used when re-encoding. 0.8 keeps payloads small without
    /// visible artifacts on photographic content; non-photographic input
    /// (UI screenshots, diagrams) may inflate slightly relative to the
    /// source PNG but the simplicity is worth it.
    static let jpegQuality: CGFloat = 0.8

    /// What `prepare` always emits — every attachment is re-encoded, so this is
    /// the mime type of any image byte-blob the app holds.
    static let mimeType = "image/jpeg"

    /// Decode `source`, downscale (preserving aspect) so the long edge is at
    /// most `maxLongEdge`, and re-encode as JPEG. Returns the encoded bytes
    /// plus the canonical mime type, or nil if the bytes couldn't be decoded
    /// as an image.
    static func prepare(_ source: Data) -> (data: Data, mimeType: String)? {
        guard let imageSource = CGImageSourceCreateWithData(source as CFData, nil) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxLongEdge),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbnailOptions as CFDictionary) else {
            return nil
        }
        let outputData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            outputData,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        let destOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
        ]
        CGImageDestinationAddImage(dest, cgImage, destOptions as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (data: outputData as Data, mimeType: mimeType)
    }
}
