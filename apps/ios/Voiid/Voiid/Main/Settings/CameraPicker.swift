//
//  CameraPicker.swift
//  Voiid
//
//  A camera capture sheet for profile photos.
//
//  WHY UIKit. SwiftUI has `PhotosPicker` for the library but no camera equivalent, so the
//  camera has to come from `UIImagePickerController`. That is not a legacy shortcut — it is
//  still the supported way to capture a still image on iOS, and wrapping it here keeps the
//  UIKit surface in one file instead of leaking into the view.
//
//  NSCameraUsageDescription IS REQUIRED. Without that key in Info.plist, iOS does not deny
//  permission — it TERMINATES the app the moment this is presented. The key was missing when
//  this was written and is added alongside it.
//

import SwiftUI
import UIKit

struct CameraPicker: UIViewControllerRepresentable {
    /// Called with the captured image. Nil is never passed — a cancel simply dismisses.
    var onCapture: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        // Guard the source: the simulator (and an iPad without a camera) has none, and
        // asking for an unavailable source shows a black screen with no way out.
        picker.sourceType = UIImagePickerController.isSourceTypeAvailable(.camera)
            ? .camera : .photoLibrary
        picker.cameraDevice = .front       // A profile photo is almost always a selfie.
        picker.allowsEditing = true        // Square crop up front, so the avatar is not a
                                           // surprise crop of whatever was framed.
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            // `.editedImage` first: with allowsEditing the user has already chosen the crop,
            // and ignoring it would silently discard their framing.
            let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage)
            picker.dismiss(animated: true)
            if let image { parent.onCapture(image) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}
