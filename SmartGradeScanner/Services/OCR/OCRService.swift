import Foundation
@preconcurrency import Vision
import CoreGraphics
import ImageIO

struct OCRService: Sendable {
    func recognizeText(in imageData: Data) async -> [String] {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithData(imageData as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [] }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false
            try? VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
            return request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        }.value
    }
}