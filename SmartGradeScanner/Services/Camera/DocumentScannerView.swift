import SwiftUI
@preconcurrency import VisionKit
import UIKit

struct DocumentScannerView: UIViewControllerRepresentable {
    let onImageData: @MainActor @Sendable (Data) -> Void
    let onCancel: @MainActor @Sendable () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController { let controller = VNDocumentCameraViewController(); controller.delegate = context.coordinator; return controller }
    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScannerView
        init(_ parent: DocumentScannerView) { self.parent = parent }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            let onCancel = parent.onCancel
            Task { @MainActor in onCancel() }
        }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            let onCancel = parent.onCancel
            Task { @MainActor in onCancel() }
        }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            guard scan.pageCount > 0 else { return }
            guard let imageData = scan.imageOfPage(at: 0).jpegData(compressionQuality: 1.0) else { return }
            let onImageData = parent.onImageData
            Task { @MainActor in
                onImageData(imageData)
            }
        }
    }
}