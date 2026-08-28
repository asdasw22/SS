import Foundation
import CoreGraphics

struct ImageQualityReport: Sendable {
    let sharpness: Double
    let brightness: Double
    let contrast: Double
    let clippedHighlights: Double
    let crushedShadows: Double

    var isUsable: Bool {
        sharpness >= 0.025 && brightness >= 0.06 && brightness <= 0.995 && contrast >= 0.025
    }

    var isAcceptable: Bool {
        sharpness >= 0.065
            && brightness >= 0.10
            && brightness <= 0.985
            && contrast >= 0.055
            && clippedHighlights <= 0.88
    }

    var score: Double {
        let sharpScore = min(1, sharpness / 0.22)
        let contrastScore = min(1, contrast / 0.20)
        let brightnessScore = max(0, 1 - abs(brightness - 0.76) / 0.76)
        let clippingPenalty = max(0, 1 - clippedHighlights * 0.45 - crushedShadows * 0.65)
        return min(1, max(0, (sharpScore * 0.42 + contrastScore * 0.30 + brightnessScore * 0.28) * clippingPenalty))
    }
}

struct ImageQualityAnalyzer: Sendable {
    func analyze(_ image: CGImage) -> ImageQualityReport {
        guard let gray = GrayImage(cgImage: image), !gray.pixels.isEmpty else {
            return ImageQualityReport(sharpness: 0,
                                      brightness: 0,
                                      contrast: 0,
                                      clippedHighlights: 1,
                                      crushedShadows: 1)
        }

        let sampleStep = max(1, min(gray.width, gray.height) / 700)
        var values: [Double] = []
        values.reserveCapacity((gray.width / sampleStep + 1) * (gray.height / sampleStep + 1))
        var highlightCount = 0
        var shadowCount = 0
        var edgeEnergy = 0.0
        var edgeCount = 0

        for y in stride(from: sampleStep, to: gray.height, by: sampleStep) {
            for x in stride(from: sampleStep, to: gray.width, by: sampleStep) {
                let current = Double(gray.value(x: x, y: y))
                values.append(current)
                if current >= 250 { highlightCount += 1 }
                if current <= 8 { shadowCount += 1 }

                let left = Double(gray.value(x: max(0, x - sampleStep), y: y))
                let up = Double(gray.value(x: x, y: max(0, y - sampleStep)))
                edgeEnergy += abs(current - left) + abs(current - up)
                edgeCount += 2
            }
        }

        guard !values.isEmpty else {
            return ImageQualityReport(sharpness: 0,
                                      brightness: 0,
                                      contrast: 0,
                                      clippedHighlights: 1,
                                      crushedShadows: 1)
        }

        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
        let sharpness = min(1, edgeEnergy / Double(max(edgeCount, 1)) / 34)
        let contrast = min(1, sqrt(max(0, variance)) / 92)
        return ImageQualityReport(
            sharpness: sharpness,
            brightness: mean / 255,
            contrast: contrast,
            clippedHighlights: Double(highlightCount) / Double(values.count),
            crushedShadows: Double(shadowCount) / Double(values.count)
        )
    }
}
