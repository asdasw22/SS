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
    profile: CalibrationProfile,
    ignoredAreas: [NormalizedRect] = []
  ) -> [DetectedMarker] {
    guard let gray = GrayImage(cgImage: image), !expected.isEmpty else { return [] }
    let size = CGSize(width: gray.width, height: gray.height)
    let ignoredRects = ignoredAreas.map(\.cgRect)
    var detected: [DetectedMarker] = []
    detected.reserveCapacity(expected.count)

    for marker in expected {
      let expectedRect = marker.expectedRect.rect(in: size)
      let baseWidth = max(expectedRect.width, 7)
      let baseHeight = max(expectedRect.height, 7)
      // Slightly wider scale/space windows: a printed sheet photographed with a
      // small page-crop error still lands inside the window, while the strong
      // fill/corner/score gates keep false positives out.
      let searchX = max(baseWidth * 4.0, size.width * 0.045)
      let searchY = max(baseHeight * 4.0, size.height * 0.045)
      let stepX = max(3, baseWidth * 0.44)
      let stepY = max(3, baseHeight * 0.44)
      let scales: [CGFloat] = [0.62, 0.74, 0.90, 1.0, 1.15, 1.32, 1.52]

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
            // Decorative page furniture (timing tracks, instructional text blocks)
            // can look like a small dark square at a distance. A candidate that
            // mostly falls inside a declared ignored area is never allowed to win,
            // which stops it from being adopted as a registration point and
            // quietly warping the homography for the bubbles near it.
            if overlapsIgnoredArea(candidate, in: size, ignoredRects: ignoredRects) {
              continue
            }
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
        bestScore >= 0.54,
        bestContrast >= max(0.035, profile.minimumLocalContrast * 0.75),
        bestFill >= 0.56,
        bestCornerFill >= 0.40
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

  private func overlapsIgnoredArea(
    _ candidatePixelRect: CGRect,
    in imageSize: CGSize,
    ignoredRects: [CGRect]
  ) -> Bool {
    guard !ignoredRects.isEmpty, imageSize.width > 0, imageSize.height > 0 else { return false }
    let fraction = CGRect(
      x: candidatePixelRect.minX / imageSize.width,
      y: candidatePixelRect.minY / imageSize.height,
      width: candidatePixelRect.width / imageSize.width,
      height: candidatePixelRect.height / imageSize.height)
    let candidateArea = max(fraction.width * fraction.height, 0.000_001)
    for rect in ignoredRects {
      let intersection = fraction.intersection(rect)
      guard !intersection.isNull else { continue }
      let overlapRatio = (intersection.width * intersection.height) / candidateArea
      if overlapRatio > 0.30 { return true }
    }
    return false
  }
}
