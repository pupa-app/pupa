#if os(iOS)
import SwiftUI
import UIKit

/// Camera capture sheet backing the composer's "Take Photo" attachment option.
/// Wraps `UIImagePickerController` with `sourceType = .camera` and hands the
/// captured shot back as JPEG `Data`. The caller runs that through
/// `ImagePreparer` — the same downscale/re-encode path photo-library picks use
/// — before attaching it. iOS-only: the camera source is unavailable on macOS
/// and the Simulator (callers gate on `isSourceTypeAvailable(.camera)`).
struct CameraPicker: UIViewControllerRepresentable {
    /// Captured image as JPEG data, or `nil` if the user cancelled. The caller
    /// dismisses the sheet either way.
    let onCapture: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (Data?) -> Void

        init(onCapture: @escaping (Data?) -> Void) {
            self.onCapture = onCapture
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            let image = info[.originalImage] as? UIImage
            // `ImagePreparer` re-encodes anyway, so a light first pass here is
            // enough — it just needs lossless-ish bytes to hand off.
            onCapture(image?.jpegData(compressionQuality: 0.9))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCapture(nil)
        }
    }
}
#endif
