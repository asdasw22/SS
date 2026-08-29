@preconcurrency import AVFoundation
import CoreImage
import CoreGraphics
import CoreMedia
import SwiftUI
import Combine

private final class CameraSessionBox: @unchecked Sendable {
    let session: AVCaptureSession
    init(session: AVCaptureSession) { self.session = session }
}

@MainActor final class CameraService: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var activeCamera: AVCaptureDevice?
    private var preferredPhotoDimensions: CMVideoDimensions?
    @Published private(set) var lastImageData: Data?
    @Published private(set) var isConfigured = false
    let liveDetector = LiveDocumentDetector()
    private let sessionQueue = DispatchQueue(label: "com.smartgrade.camera.session", qos: .userInitiated)

    func configure() async {
        guard await CameraPermissionService.request(), !isConfigured else { return }
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input),
              session.canAddOutput(output) else {
            session.commitConfiguration()
            return
        }

        configureDevice(camera)
        session.addInput(input)
        session.addOutput(output)
        activeCamera = camera
        if let largest = camera.activeFormat.supportedMaxPhotoDimensions.max(by: {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }) {
            output.maxPhotoDimensions = largest
            preferredPhotoDimensions = largest
        }
        output.maxPhotoQualityPrioritization = .quality
        liveDetector.attach(to: session)
        session.commitConfiguration()
        isConfigured = true

        let sessionBox = CameraSessionBox(session: session)
        sessionQueue.async { sessionBox.session.startRunning() }
    }

    func capture() {
        guard isConfigured, session.isRunning else { return }
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        settings.photoQualityPrioritization = .quality
        if let preferredPhotoDimensions {
            settings.maxPhotoDimensions = preferredPhotoDimensions
        }
        output.capturePhoto(with: settings, delegate: self)
    }

    /// Ensures the AV session is configured and actually running before taking a
    /// photo. This makes the visible Fast OMR control deterministic instead of
    /// silently sending a capture request to an output that has not started yet.
    func captureWhenReady() async -> Bool {
        if !isConfigured { await configure() }
        guard isConfigured else { return false }

        for _ in 0..<24 {
            if session.isRunning {
                break
            }
            try? await Task<Never, Never>.sleep(nanoseconds: 50_000_000)
        }
        guard session.isRunning else { return false }

        // Give continuous autofocus/exposure a short, bounded opportunity to settle.
        // Capture still proceeds after the deadline, so this never hangs the UI.
        for _ in 0..<16 {
            guard let camera = activeCamera,
                camera.isAdjustingFocus || camera.isAdjustingExposure
            else { break }
            try? await Task<Never, Never>.sleep(nanoseconds: 50_000_000)
        }
        capture()
        return true
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        Task { @MainActor [weak self] in self?.lastImageData = data }
    }

    func stop() {
        let sessionBox = CameraSessionBox(session: session)
        sessionQueue.async {
            if sessionBox.session.isRunning { sessionBox.session.stopRunning() }
        }
    }

    private func configureDevice(_ camera: AVCaptureDevice) {
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }
            if camera.isFocusModeSupported(.continuousAutoFocus) {
                camera.focusMode = .continuousAutoFocus
            }
            if camera.isExposureModeSupported(.continuousAutoExposure) {
                camera.exposureMode = .continuousAutoExposure
            }
            if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                camera.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            if camera.isSmoothAutoFocusSupported {
                camera.isSmoothAutoFocusEnabled = true
            }
            if camera.isLowLightBoostSupported {
                camera.automaticallyEnablesLowLightBoostWhenAvailable = true
            }
        } catch {
            // Camera configuration is an enhancement; scanning still works with defaults.
        }
    }
}
