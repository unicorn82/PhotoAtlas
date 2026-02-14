import SwiftUI
import PhotosUI

/// iOS 15-friendly photo picker (PHPicker).
struct UIKitPhotoPicker: UIViewControllerRepresentable {
    typealias UIViewControllerType = PHPickerViewController

    var maxSelectionCount: Int = 9
    var onPicked: ([UIImage]) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = maxSelectionCount

        let vc = PHPickerViewController(configuration: config)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {
        // no-op
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked)
    }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: ([UIImage]) -> Void

        init(onPicked: @escaping ([UIImage]) -> Void) {
            self.onPicked = onPicked
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            guard !results.isEmpty else {
                onPicked([])
                return
            }

            var images: [UIImage] = []
            let group = DispatchGroup()

            for r in results {
                let provider = r.itemProvider
                if provider.canLoadObject(ofClass: UIImage.self) {
                    group.enter()
                    provider.loadObject(ofClass: UIImage.self) { obj, _ in
                        defer { group.leave() }
                        if let img = obj as? UIImage {
                            images.append(img)
                        }
                    }
                }
            }

            group.notify(queue: .main) {
                // Keep deterministic order-ish.
                self.onPicked(images)
            }
        }
    }
}
