import SwiftUI
import UIKit

/// Thin SwiftUI wrapper over `UIImagePickerController` for grabbing a single still image
/// from the camera or the photo library (SwiftUI's `PhotosPicker` can't reach the camera).
/// `onImage` is called once with the chosen image, or nil if the user cancels.
struct CameraImagePicker: UIViewControllerRepresentable {
    enum Source { case camera, library }

    let source: Source
    let onImage: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        // Fall back to the library if the camera isn't available (e.g. Simulator).
        picker.sourceType = (source == .camera && UIImagePickerController.isSourceTypeAvailable(.camera))
            ? .camera : .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onImage: onImage) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onImage: (UIImage?) -> Void
        private var handled = false

        init(onImage: @escaping (UIImage?) -> Void) { self.onImage = onImage }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard !handled else { return }
            handled = true
            onImage(info[.originalImage] as? UIImage)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            guard !handled else { return }
            handled = true
            onImage(nil)
        }
    }
}
