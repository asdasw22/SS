import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import Vision

struct DetectedDocument: Sendable {
  let normalizedCorners: [CGPoint]
  let confidence: Float
  let usedFullFrameFallback: Bool
}

enum DocumentDetectionError: LocalizedError {
  case notFound

  var errorDescription: String? {
    "The full answer sheet was not detected. Do not crop around the Student ID table. Keep the whole page and all black registration squares visible, then scan again."
  }
}

struct DocumentDetectionService: Sendable {
  func detect(in image: CGImage, expectedAspectRatio: Double) throws -> DetectedDocument {
    // Fast path: images selected from Photos or returned by a scanner are often
    // already cropped to the whole page. Accepting the full frame FIRST prevents
    // Vision from choosing the inner Student-ID table as a document rectangle.
    if canUseFullFrame(image: image, expectedAspectRatio: expectedAspectRatio) {
      return DetectedDocument(
        normalizedCorners: [
          CGPoint(x: 0, y: 1),
          CGPoint(x: 1, y: 1),
          CGPoint(x: 1, y: 0),
          CGPoint(x: 0, y: 0),
        ],
        confidence: 0.97,
        usedFullFrameFallback: true)
    }

    let request = VNDetectRectanglesRequest()
    let expectedShortLong = Float(min(expectedAspectRatio, 1 / max(expectedAspectRatio, 0.001)))
    request.minimumAspectRatio = max(0.55, expectedShortLong - 0.14)
    request.maximumAspectRatio = min(1.0, expectedShortLong + 0.14)
    request.minimumSize = 0.42
    request.minimumConfidence = 0.30
    request.maximumObservations = 8
    request.quadratureTolerance = 30

    try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
    let observations = request.results ?? []

    let candidates = observations.compactMap { observation -> (VNRectangleObservation, Double, Double)? in
      let area = Double(
        polygonArea([
          observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft,
        ]))
      // A page must occupy a large fraction of the image. The ID table and answer
      // blocks are intentionally too small to pass this gate.
      guard area >= 0.40 else { return nil }
      let aspect = aspectScore(observation, expectedAspectRatio: expectedAspectRatio)
      guard aspect >= 0.58 else { return nil }
      let score = candidateScore(
        observation,
        expectedAspectRatio: expectedAspectRatio,
        area: area,
        aspect: aspect)
      return (observation, score, area)
    }

    guard let best = candidates.max(by: { lhs, rhs in
      if abs(lhs.2 - rhs.2) > 0.035 { return lhs.2 < rhs.2 }
      return lhs.1 < rhs.1
    }) else {
      throw DocumentDetectionError.notFound
    }

    let observation = best.0
    guard best.2 >= 0.40, observation.confidence >= 0.34 else {
      throw DocumentDetectionError.notFound
    }

    return DetectedDocument(
      normalizedCorners: [
        observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft,
      ],
      confidence: Float(min(1, max(Double(observation.confidence), best.1))),
      usedFullFrameFallback: false)
  }

  private func candidateScore(
    _ observation: VNRectangleObservation,
    expectedAspectRatio: Double,
    area: Double,
    aspect: Double
  ) -> Double {
    let areaScore = min(1, max(0, area / 0.72))
    let center = CGPoint(x: observation.boundingBox.midX, y: observation.boundingBox.midY)
    let centerDistance = hypot(Double(center.x - 0.5), Double(center.y - 0.5))
    let centerScore = min(1, max(0, 1 - centerDistance / 0.60))

    return areaScore * 0.48
      + aspect * 0.31
      + Double(observation.confidence) * 0.16
      + centerScore * 0.05
  }

  private func aspectScore(_ observation: VNRectangleObservation, expectedAspectRatio: Double)
    -> Double {
    let top = distance(observation.topLeft, observation.topRight)
    let bottom = distance(observation.bottomLeft, observation.bottomRight)
    let left = distance(observation.topLeft, observation.bottomLeft)
    let right = distance(observation.topRight, observation.bottomRight)
    let observedRatio = Double((top + bottom) / max(left + right, 0.0001))
    let expected = max(expectedAspectRatio, 0.001)
    let direct = exp(-abs(log(max(observedRatio, 0.001) / expected)) * 4.8)
    let rotated = exp(-abs(log(max(1 / max(observedRatio, 0.001), 0.001) / expected)) * 4.8)
    return max(direct, rotated)
  }

  private func canUseFullFrame(image: CGImage, expectedAspectRatio: Double) -> Bool {
    guard image.width >= 500, image.height >= 350 else { return false }
    let imageRatio = Double(image.width) / Double(max(image.height, 1))
    let expected = max(expectedAspectRatio, 0.001)
    let directDelta = abs(log(max(imageRatio, 0.001) / expected))
    let rotatedDelta = abs(log(max(1 / max(imageRatio, 0.001), 0.001) / expected))
    guard min(directDelta, rotatedDelta) <= log(1.16) else { return false }
    guard let gray = GrayImage(cgImage: image) else { return false }

    let w = CGFloat(gray.width)
    let h = CGFloat(gray.height)
    let strip = max(6, min(w, h) * 0.026)
    let edges = [
      CGRect(x: 0, y: 0, width: w, height: strip),
      CGRect(x: 0, y: h - strip, width: w, height: strip),
      CGRect(x: 0, y: 0, width: strip, height: h),
      CGRect(x: w - strip, y: 0, width: strip, height: h),
    ]
    let edgeLightness =
      edges.map { gray.lightFraction(in: $0, threshold: 135, step: 5) }.reduce(0, +)
      / Double(edges.count)
    return edgeLightness >= 0.54
  }

  private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
    hypot(a.x - b.x, a.y - b.y)
  }

  private func polygonArea(_ points: [CGPoint]) -> CGFloat {
    guard points.count >= 3 else { return 0 }
    var sum: CGFloat = 0
    for index in points.indices {
      let next = points[(index + 1) % points.count]
      sum += points[index].x * next.y - next.x * points[index].y
    }
    return abs(sum) / 2
  }
}
