@preconcurrency import AVFoundation
@preconcurrency import Vision
import Combine
import CoreMedia
import CoreVideo
import CoreGraphics

@MainActor final class LiveDocumentDetector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, ObservableObject {
    @Published private(set) var documentConfidence: Double = 0
    @Published private(set) var isReady = false

    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "com.smartgrade.live-document", qos: .userInitiated)
    private var stableFrames = 0

    func attach(to session: AVCaptureSession) {
        guard !session.outputs.contains(where: { $0 === output }), session.canAddOutput(output) else { return }
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(output)
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let request = VNDetectRectanglesRequest { request, _ in
            let observations = request.results as? [VNRectangleObservation] ?? []
            let candidates = observations.compactMap { observation -> (Double, Double, Double)? in
                let top = hypot(observation.topRight.x - observation.topLeft.x,
                                observation.topRight.y - observation.topLeft.y)
                let bottom = hypot(observation.bottomRight.x - observation.bottomLeft.x,
                                   observation.bottomRight.y - observation.bottomLeft.y)
                let left = hypot(observation.topLeft.x - observation.bottomLeft.x,
                                 observation.topLeft.y - observation.bottomLeft.y)
                let right = hypot(observation.topRight.x - observation.bottomRight.x,
                                  observation.topRight.y - observation.bottomRight.y)
                let ratio = Double((top + bottom) / max(left + right, 0.0001))
                // The only physical sheet this app scans: the fixed 904x1280
                // strict OMR template. No legacy competing ratios remain.
                let supported = [904.0 / 1280.0]
                let aspect = supported.reduce(0.0) { best, expected in
                    let direct = exp(-abs(log(max(ratio, 0.001) / max(expected, 0.001))) * 4.2)
                    let rotated = exp(-abs(log(max(1 / max(ratio, 0.001), 0.001) / max(expected, 0.001))) * 4.2)
                    return max(best, max(direct, rotated))
                }
                let area = Double(observation.boundingBox.width * observation.boundingBox.height)
                guard area >= 0.10, aspect >= 0.30 else { return nil }
                let score = area * 0.58 + aspect * 0.28 + Double(observation.confidence) * 0.14
                return (score, aspect, area)
            }
            let best = candidates.max { $0.0 < $1.0 }
            Task { @MainActor [weak self] in
                self?.update(
                    confidence: best?.0 ?? 0,
                    aspectScore: best?.1 ?? 0,
                    area: best?.2 ?? 0)
            }
        }
        request.minimumSize = 0.10
        request.minimumAspectRatio = 0.34
        request.maximumAspectRatio = 1.0
        request.minimumConfidence = 0.12
        request.maximumObservations = 6
        request.quadratureTolerance = 42
        try? VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .right).perform([request])
    }

    private func update(confidence: Double, aspectScore: Double, area: Double) {
        let areaScore = min(1, max(0, area / 0.42))
        let score = min(1, max(0, confidence * 0.68 + areaScore * 0.32))
        documentConfidence = score

        if score >= 0.42 && aspectScore >= 0.38 && area >= 0.12 {
            stableFrames = min(5, stableFrames + 1)
        } else {
            stableFrames = max(0, stableFrames - 2)
        }
        isReady = stableFrames >= 1
    }
}
