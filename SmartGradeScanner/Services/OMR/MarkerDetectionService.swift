import CoreGraphics
import Foundation

struct DetectedMarker: Sendable {
  let expectedCenter: CGPoint
  let center: CGPoint
  let confidence: Double
  let kind: MarkerKind
}

struct MarkerDetectionService: Sendable {
  func detect(
    in image: CGImage,
    expected: [MarkerDefinition],
    profile: CalibrationProfile
  ) -> [DetectedMarker] {
    guard let gray = GrayImage(cgImage: image), !expected.isEmpty else { return [] }
    let size = CGSize(width: gray.width, height: gray.height)
    var detected: [DetectedMarker] = []
    detected.reserveCapacity(expected.count)

    for marker in expected {
      let expectedRect = marker.expectedRect.rect(in: size)
      let baseWidth = max(expectedRect.width, 7)
      let baseHeight = max(expectedRect.height, 7)
      let searchX = max(baseWidth * 2.5, size.width * 0.022)
      let searchY = max(baseHeight * 2.5, size.height * 0.022)
      let stepX = max(2, baseWidth * 0.20)
      let stepY = max(2, baseHeight * 0.20)
      let scales: [CGFloat] = [0.80, 0.92, 1.0, 1.10, 1.22]

      var bestRect: CGRect?
      var bestScore = 0.0
      var bestContrast = 0.0
      var bestFill = 0.0
      var bestCornerFill = 0.0

      var y = -searchY
      while y <= searchY {
        var x = -searchX
        while x <= searchX {
          for scale in scales {
            let width = baseWidth * scale
            let height = baseHeight * scale
            let candidate = CGRect(
              x: expectedRect.midX + x - width / 2,
              y: expectedRect.midY + y - height / 2,
              width: width,
              height: height)
            let stats = gray.markerStatistics(in: candidate)
            let normalizedOffset = hypot(
              Double(x / max(searchX, 1)),
              Double(y / max(searchY, 1)))
            let offsetPenalty = min(0.22, normalizedOffset * 0.10)
            let scalePenalty = abs(Double(scale - 1)) * 0.07
            let score = stats.score - offsetPenalty - scalePenalty
            if score > bestScore {
              bestScore = score
              bestRect = candidate
              bestContrast = stats.contrast
              bestFill = stats.fillRatio
              bestCornerFill = stats.cornerFill
            }
          }
          x += stepX
        }
        y += stepY
      }

      // A real registration mark is a solid square. The corner-fill requirement is
      // what stops filled circular answer bubbles from being accepted as markers.
      guard let bestRect,
        bestScore >= 0.66,
        bestContrast >= max(0.06, profile.minimumLocalContrast),
        bestFill >= 0.68,
        bestCornerFill >= 0.52
      else { continue }

      let center = CGPoint(
        x: bestRect.midX / size.width,
        y: bestRect.midY / size.height)
      detected.append(
        DetectedMarker(
          expectedCenter: marker.expectedRect.center,
          center: center,
          confidence: min(1, max(0, bestScore)),
          kind: marker.kind))
    }

    let sorted = detected.sorted { $0.confidence > $1.confidence }
    var unique: [DetectedMarker] = []
    for marker in sorted {
      let duplicate = unique.contains {
        hypot(Double($0.center.x - marker.center.x), Double($0.center.y - marker.center.y)) < 0.012
      }
      if !duplicate { unique.append(marker) }
    }
    return unique
  }
}
