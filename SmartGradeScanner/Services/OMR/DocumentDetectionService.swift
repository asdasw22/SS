import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import Vision

enum DocumentCandidateSource: String, Codable, Sendable {
  case fiducialMarkers
  case visionPage
  case fullFrame
}

struct DetectedDocument: Sendable {
  /// Corners in Vision/Core Image normalized coordinates (origin at bottom-left),
  /// ordered top-left, top-right, bottom-right, bottom-left.
  let normalizedCorners: [CGPoint]
  let confidence: Float
  let usedFullFrameFallback: Bool
  let source: DocumentCandidateSource
  let area: Double
  let aspectScore: Double
}

enum DocumentDetectionError: LocalizedError {
  case notFound

  var errorDescription: String? {
    "The answer sheet could not be registered automatically. Keep the page reasonably visible, or import the image from Photos. Fast OMR now also tries the printed black registration squares even when the page border is not detected."
  }
}

/// Produces several page hypotheses instead of committing to the first rectangle.
/// The OMR processor validates every candidate against the printed registration marks
/// and selects the candidate that actually matches the template.
struct DocumentDetectionService: Sendable {
  private let fiducialLocator = FiducialPageLocator()

  func detect(in image: CGImage, expectedAspectRatio: Double) throws -> DetectedDocument {
    let values = try candidates(in: image, expectedAspectRatio: expectedAspectRatio, template: nil)
    guard let best = values.first else { throw DocumentDetectionError.notFound }
    return best
  }

  func candidates(
    in image: CGImage,
    expectedAspectRatio: Double,
    template: TemplateDefinition?
  ) throws -> [DetectedDocument] {
    var result: [DetectedDocument] = []

    // Marker-first registration is the preferred path for phone images. It does not
    // require the white page border to be visible and therefore works when the sheet
    // is photographed on a desk, on a monitor, or with background clutter.
    if let template,
      template.markers.count >= 4,
      let markerPage = try? fiducialLocator.locate(in: image, template: template)
    {
      result.append(markerPage)
    }

    // A photo-library image or scanner output is often already cropped to the page.
    // Keep this as a cheap candidate, but never trust it until OMR marker validation.
    if canUseFullFrame(image: image, expectedAspectRatio: expectedAspectRatio) {
      result.append(
        DetectedDocument(
          normalizedCorners: [
            CGPoint(x: 0, y: 1),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 1, y: 0),
            CGPoint(x: 0, y: 0),
          ],
          confidence: 0.91,
          usedFullFrameFallback: true,
          source: .fullFrame,
          area: 1,
          aspectScore: 1))
    }

    let request = VNDetectRectanglesRequest()
    let expectedShortLong = Float(min(expectedAspectRatio, 1 / max(expectedAspectRatio, 0.001)))
    // Previous revisions were too strict here: a phone view with perspective or a
    // sheet occupying only ~20-35% of the frame was rejected before markers were
    // even examined. Keep the page detector deliberately permissive and let marker
    // validation decide which rectangle is the answer sheet.
    request.minimumAspectRatio = max(0.34, expectedShortLong - 0.32)
    request.maximumAspectRatio = min(1.0, expectedShortLong + 0.22)
    request.minimumSize = 0.11
    request.minimumConfidence = 0.14
    request.maximumObservations = 12
    request.quadratureTolerance = 42

    try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
    let observations = request.results ?? []

    let visionCandidates = observations.compactMap { observation -> DetectedDocument? in
      let area = Double(
        polygonArea([
          observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft,
        ]))
      guard area >= 0.075 else { return nil }
      let aspect = aspectScore(observation, expectedAspectRatio: expectedAspectRatio)
      guard aspect >= 0.26 else { return nil }
      let score = candidateScore(
        observation,
        expectedAspectRatio: expectedAspectRatio,
        area: area,
        aspect: aspect)
      guard score >= 0.24 else { return nil }
      return DetectedDocument(
        normalizedCorners: [
          observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft,
        ],
        confidence: Float(min(1, max(Double(observation.confidence), score))),
        usedFullFrameFallback: false,
        source: .visionPage,
        area: area,
        aspectScore: aspect)
    }
    .sorted {
      // Prefer a strong aspect match, but do not automatically choose the largest
      // rectangle (which may be a monitor or desk). OMR markers will re-rank later.
      let lhs = Double($0.confidence) * 0.58 + $0.aspectScore * 0.30 + min(1, $0.area / 0.55) * 0.12
      let rhs = Double($1.confidence) * 0.58 + $1.aspectScore * 0.30 + min(1, $1.area / 0.55) * 0.12
      return lhs > rhs
    }

    for candidate in visionCandidates.prefix(4) {
      if !result.contains(where: { cornerDistance($0.normalizedCorners, candidate.normalizedCorners) < 0.045 }) {
        result.append(candidate)
      }
    }

    // Marker-derived candidates are kept first. The rest are ranked by confidence.
    let marker = result.filter { $0.source == .fiducialMarkers }
    let others = result.filter { $0.source != .fiducialMarkers }.sorted { $0.confidence > $1.confidence }
    let combined = marker + others
    guard !combined.isEmpty else { throw DocumentDetectionError.notFound }
    return Array(combined.prefix(5))
  }

  private func candidateScore(
    _ observation: VNRectangleObservation,
    expectedAspectRatio: Double,
    area: Double,
    aspect: Double
  ) -> Double {
    let areaScore = min(1, max(0, area / 0.55))
    let center = CGPoint(x: observation.boundingBox.midX, y: observation.boundingBox.midY)
    let centerDistance = hypot(Double(center.x - 0.5), Double(center.y - 0.5))
    let centerScore = min(1, max(0, 1 - centerDistance / 0.72))

    return areaScore * 0.34
      + aspect * 0.38
      + Double(observation.confidence) * 0.18
      + centerScore * 0.10
  }

  private func aspectScore(_ observation: VNRectangleObservation, expectedAspectRatio: Double)
    -> Double {
    let top = distance(observation.topLeft, observation.topRight)
    let bottom = distance(observation.bottomLeft, observation.bottomRight)
    let left = distance(observation.topLeft, observation.bottomLeft)
    let right = distance(observation.topRight, observation.bottomRight)
    let observedRatio = Double((top + bottom) / max(left + right, 0.0001))
    let expected = max(expectedAspectRatio, 0.001)
    let direct = exp(-abs(log(max(observedRatio, 0.001) / expected)) * 3.3)
    let rotated = exp(-abs(log(max(1 / max(observedRatio, 0.001), 0.001) / expected)) * 3.3)
    return max(direct, rotated)
  }

  private func canUseFullFrame(image: CGImage, expectedAspectRatio: Double) -> Bool {
    guard image.width >= 420, image.height >= 320 else { return false }
    let imageRatio = Double(image.width) / Double(max(image.height, 1))
    let expected = max(expectedAspectRatio, 0.001)
    let directDelta = abs(log(max(imageRatio, 0.001) / expected))
    let rotatedDelta = abs(log(max(1 / max(imageRatio, 0.001), 0.001) / expected))
    guard min(directDelta, rotatedDelta) <= log(1.28) else { return false }
    guard let gray = GrayImage(cgImage: image) else { return false }

    let w = CGFloat(gray.width)
    let h = CGFloat(gray.height)
    let strip = max(6, min(w, h) * 0.024)
    let edges = [
      CGRect(x: 0, y: 0, width: w, height: strip),
      CGRect(x: 0, y: h - strip, width: w, height: strip),
      CGRect(x: 0, y: 0, width: strip, height: h),
      CGRect(x: w - strip, y: 0, width: strip, height: h),
    ]
    let edgeLightness =
      edges.map { gray.lightFraction(in: $0, threshold: 130, step: 6) }.reduce(0, +)
      / Double(edges.count)
    return edgeLightness >= 0.42
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

  private func cornerDistance(_ lhs: [CGPoint], _ rhs: [CGPoint]) -> Double {
    guard lhs.count == 4, rhs.count == 4 else { return .greatestFiniteMagnitude }
    return zip(lhs, rhs).map { hypot(Double($0.0.x - $0.1.x), Double($0.0.y - $0.1.y)) }
      .reduce(0, +) / 4
  }
}

// MARK: - Marker-first page locator

private struct RawFiducial: Sendable {
  let center: CGPoint  // normalized, top-left origin
  let normalizedSize: CGSize
  let confidence: Double

  var priority: Double {
    let geometricSize = sqrt(max(0, Double(normalizedSize.width * normalizedSize.height)))
    return confidence + min(0.22, geometricSize * 12.0)
  }
}

/// Recovers the page from the printed black squares even when the outer page edge
/// is not visible. Candidate outer-marker quads are fitted with a projective
/// homography, then the remaining markers validate the recovered page geometry.
private struct FiducialPageLocator: Sendable {
  private let homography = HomographySolver()

  func locate(in image: CGImage, template: TemplateDefinition) throws -> DetectedDocument? {
    let expected = template.markers.filter { $0.kind == .registration }.map { $0.expectedRect.center }
    guard expected.count >= 4 else { return nil }

    // Prefer a direct connected-component search for solid black squares. It is
    // deterministic and does not depend on Vision deciding that a tiny filled
    // square is a "document rectangle". Vision candidates are merged as backup.
    var candidates = componentCandidates(in: image)
    if candidates.count < 12 {
      candidates.append(contentsOf: try visionMarkerCandidates(in: image))
    }
    candidates = deduplicated(candidates)
    guard candidates.count >= 4 else { return nil }

    guard let match = bestMatch(expected: expected, candidates: candidates) else { return nil }
    let source = match.map { expected[$0.expectedIndex] }
    let destination = match.map { candidates[$0.candidateIndex].center }

    guard var transform = homography.solve(source: source, destination: destination) else { return nil }
    var residuals = zip(source, destination).map { homography.distance(transform.apply($0.0), $0.1) }
    let tolerance = max(0.016, median(residuals) * 2.7)
    let inlierIndices = residuals.indices.filter { residuals[$0] <= tolerance }
    if inlierIndices.count >= 4, inlierIndices.count < source.count {
      let refinedSource = inlierIndices.map { source[$0] }
      let refinedDestination = inlierIndices.map { destination[$0] }
      if let refined = homography.solve(source: refinedSource, destination: refinedDestination) {
        transform = refined
        residuals = zip(refinedSource, refinedDestination).map {
          homography.distance(transform.apply($0.0), $0.1)
        }
      }
    }

    let topLeft = transform.apply(CGPoint(x: 0, y: 0))
    let topRight = transform.apply(CGPoint(x: 1, y: 0))
    let bottomRight = transform.apply(CGPoint(x: 1, y: 1))
    let bottomLeft = transform.apply(CGPoint(x: 0, y: 1))
    let topOriginCorners = [topLeft, topRight, bottomRight, bottomLeft]

    guard topOriginCorners.allSatisfy({
      $0.x >= -0.10 && $0.x <= 1.10 && $0.y >= -0.10 && $0.y <= 1.10
    }) else { return nil }

    let pageArea = Double(polygonArea(topOriginCorners))
    guard pageArea >= 0.055 else { return nil }

    let meanResidual = residuals.reduce(0, +) / Double(max(residuals.count, 1))
    let meanConfidence = match.map { candidates[$0.candidateIndex].confidence }.reduce(0, +)
      / Double(max(match.count, 1))
    let countScore = min(1, Double(match.count) / Double(max(expected.count, 1)))
    let residualScore = max(0, 1 - meanResidual / 0.055)
    let confidence = min(1, countScore * 0.54 + residualScore * 0.30 + meanConfidence * 0.16)
    guard match.count >= 4, confidence >= 0.43 else { return nil }

    // Convert top-left normalized coordinates back to Vision/Core Image coordinates.
    let visionCorners = topOriginCorners.map { CGPoint(x: $0.x, y: 1 - $0.y) }
    return DetectedDocument(
      normalizedCorners: visionCorners,
      confidence: Float(confidence),
      usedFullFrameFallback: false,
      source: .fiducialMarkers,
      area: pageArea,
      aspectScore: 1)
  }

  private func componentCandidates(in image: CGImage) -> [RawFiducial] {
    let working = ImagePreprocessor().resizedImage(from: image, longEdge: 1400) ?? image
    guard let gray = GrayImage(cgImage: working) else { return [] }
    let width = gray.width
    let height = gray.height
    guard width >= 120, height >= 120 else { return [] }

    let threshold: UInt8 = 112
    var visited = [UInt8](repeating: 0, count: width * height)
    var result: [RawFiducial] = []
    let minDimension = Double(min(width, height))
    let minSide = max(4, Int((minDimension * 0.0035).rounded(.down)))
    let maxSide = max(minSide + 2, Int((minDimension * 0.095).rounded(.up)))

    var queue: [Int] = []
    queue.reserveCapacity(4096)

    for y in 0..<height {
      for x in 0..<width {
        let seed = y * width + x
        if visited[seed] != 0 || gray.pixels[seed] >= threshold { continue }

        queue.removeAll(keepingCapacity: true)
        queue.append(seed)
        visited[seed] = 1
        var cursor = 0
        var count = 0
        var minX = x
        var maxX = x
        var minY = y
        var maxY = y

        while cursor < queue.count {
          let index = queue[cursor]
          cursor += 1
          let cx = index % width
          let cy = index / width
          count += 1
          minX = min(minX, cx)
          maxX = max(maxX, cx)
          minY = min(minY, cy)
          maxY = max(maxY, cy)

          for ny in max(0, cy - 1)...min(height - 1, cy + 1) {
            for nx in max(0, cx - 1)...min(width - 1, cx + 1) {
              if nx == cx && ny == cy { continue }
              let neighbor = ny * width + nx
              if visited[neighbor] == 0 && gray.pixels[neighbor] < threshold {
                visited[neighbor] = 1
                queue.append(neighbor)
              }
            }
          }
        }

        let boxWidth = maxX - minX + 1
        let boxHeight = maxY - minY + 1
        guard boxWidth >= minSide, boxHeight >= minSide,
          boxWidth <= maxSide, boxHeight <= maxSide
        else { continue }
        let aspect = Double(boxWidth) / Double(max(boxHeight, 1))
        guard aspect >= 0.54, aspect <= 1.70 else { continue }
        let solidity = Double(count) / Double(max(boxWidth * boxHeight, 1))
        guard solidity >= 0.42 else { continue }

        let rect = CGRect(x: minX, y: minY, width: boxWidth, height: boxHeight)
        let stats = gray.markerStatistics(in: rect)
        guard stats.cornerFill >= 0.34,
          stats.fillRatio >= 0.46,
          stats.score >= 0.38,
          stats.contrast >= 0.020
        else { continue }

        let shapeScore = max(0, 1 - abs(log(max(aspect, 0.001))) / 0.55)
        let confidence = min(
          1,
          max(0, stats.score * 0.50 + stats.cornerFill * 0.20 + solidity * 0.18 + shapeScore * 0.12))
        result.append(
          RawFiducial(
            center: CGPoint(
              x: (Double(minX + maxX) * 0.5) / Double(width),
              y: (Double(minY + maxY) * 0.5) / Double(height)),
            normalizedSize: CGSize(
              width: Double(boxWidth) / Double(width),
              height: Double(boxHeight) / Double(height)),
            confidence: confidence))
      }
    }
    return Array(result.sorted(by: { $0.confidence > $1.confidence }).prefix(48))
  }

  private func visionMarkerCandidates(in image: CGImage) throws -> [RawFiducial] {
    let request = VNDetectRectanglesRequest()
    request.minimumAspectRatio = 0.50
    request.maximumAspectRatio = 1.0
    request.minimumSize = 0.003
    request.minimumConfidence = 0.08
    request.maximumObservations = 16
    request.quadratureTolerance = 32
    try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])

    guard let gray = GrayImage(cgImage: image) else { return [] }
    let size = CGSize(width: gray.width, height: gray.height)
    var result: [RawFiducial] = []
    for observation in request.results ?? [] {
      let box = observation.boundingBox
      let area = Double(box.width * box.height)
      guard area >= 0.000_008, area <= 0.028 else { continue }
      let pixelRect = CGRect(
        x: box.minX * size.width,
        y: (1 - box.maxY) * size.height,
        width: box.width * size.width,
        height: box.height * size.height)
      let stats = gray.markerStatistics(in: pixelRect)
      guard stats.fillRatio >= 0.42,
        stats.cornerFill >= 0.31,
        stats.score >= 0.35,
        stats.contrast >= 0.018
      else { continue }
      let confidence = min(
        1,
        stats.score * 0.62 + stats.cornerFill * 0.20 + Double(observation.confidence) * 0.18)
      result.append(
        RawFiducial(
          center: CGPoint(x: box.midX, y: 1 - box.midY),
          normalizedSize: CGSize(width: box.width, height: box.height),
          confidence: confidence))
    }
    return result
  }

  private struct Match {
    let expectedIndex: Int
    let candidateIndex: Int
    let residual: Double
  }

  private func bestMatch(expected: [CGPoint], candidates: [RawFiducial]) -> [Match]? {
    guard expected.count >= 4, candidates.count >= 4 else { return nil }
    guard let outer = outerMarkerIndices(expected) else { return nil }
    let expectedOuter = outer.map { expected[$0] }

    // A similarity transform in normalized coordinates is not reliable when a
    // landscape sheet is photographed inside a portrait camera frame: x and y use
    // different normalization scales and perspective adds further distortion.
    // Instead, enumerate plausible upright quadrilaterals, solve a true projective
    // homography from the four outer registration marks, then validate every other
    // printed marker against that homography. With <=24 candidates this is only
    // ~10k quads and is still fast on-device after the component pass is downsized.
    var best: [Match] = []
    var bestScore = -Double.greatestFiniteMagnitude
    let n = candidates.count

    for a in 0..<(n - 3) {
      for b in (a + 1)..<(n - 2) {
        for c in (b + 1)..<(n - 1) {
          for d in (c + 1)..<n {
            guard let ordered = orderedUprightQuad(
              indices: [a, b, c, d], candidates: candidates)
            else { continue }
            let destinationOuter = ordered.map { candidates[$0].center }
            guard let transform = homography.solve(
              source: expectedOuter, destination: destinationOuter)
            else { continue }

            let pageCorners = [
              transform.apply(CGPoint(x: 0, y: 0)),
              transform.apply(CGPoint(x: 1, y: 0)),
              transform.apply(CGPoint(x: 1, y: 1)),
              transform.apply(CGPoint(x: 0, y: 1)),
            ]
            guard pageCorners.allSatisfy({
              $0.x >= -0.10 && $0.x <= 1.10 && $0.y >= -0.10 && $0.y <= 1.10
            }) else { continue }
            let pageArea = Double(polygonArea(pageCorners))
            guard pageArea >= 0.055, pageArea <= 1.10 else { continue }

            let tolerance = max(0.014, min(0.036, sqrt(pageArea) * 0.060))
            var used = Set<Int>()
            var matches: [Match] = []
            for (expectedIndex, point) in expected.enumerated() {
              let predicted = transform.apply(point)
              var nearestIndex: Int?
              var nearestDistance = Double.greatestFiniteMagnitude
              for candidateIndex in candidates.indices where !used.contains(candidateIndex) {
                let distance = homography.distance(predicted, candidates[candidateIndex].center)
                if distance < nearestDistance {
                  nearestDistance = distance
                  nearestIndex = candidateIndex
                }
              }
              if let nearestIndex, nearestDistance <= tolerance {
                used.insert(nearestIndex)
                matches.append(
                  Match(
                    expectedIndex: expectedIndex,
                    candidateIndex: nearestIndex,
                    residual: nearestDistance))
              }
            }

            guard matches.count >= 5 else { continue }
            let meanResidual = matches.map(\.residual).reduce(0, +) / Double(matches.count)
            let meanConfidence = matches.map { candidates[$0.candidateIndex].confidence }.reduce(0, +)
              / Double(matches.count)
            let coverage = Double(matches.count) / Double(expected.count)
            let score = Double(matches.count) * 2.05
              + meanConfidence * 0.70
              + coverage * 0.80
              - meanResidual * 34.0
            if score > bestScore {
              bestScore = score
              best = matches
            }
          }
        }
      }
    }
    return best.count >= 5 ? best : nil
  }

  /// Returns the expected outer marks in TL, TR, BR, BL order. Registration layouts
  /// do not need to be exactly 3x3; only four spatially distributed outer points are
  /// required.
  private func outerMarkerIndices(_ points: [CGPoint]) -> [Int]? {
    guard points.count >= 4 else { return nil }
    let tl = points.indices.min { (points[$0].x + points[$0].y) < (points[$1].x + points[$1].y) }
    let tr = points.indices.max { (points[$0].x - points[$0].y) < (points[$1].x - points[$1].y) }
    let br = points.indices.max { (points[$0].x + points[$0].y) < (points[$1].x + points[$1].y) }
    let bl = points.indices.min { (points[$0].x - points[$0].y) < (points[$1].x - points[$1].y) }
    guard let tl, let tr, let br, let bl else { return nil }
    let values = [tl, tr, br, bl]
    guard Set(values).count == 4 else { return nil }
    return values
  }

  /// Orders a candidate quad assuming the printed sheet is roughly upright in the
  /// EXIF-normalized photo. This intentionally rejects 180-degree false matches from
  /// the symmetric 3x3 square pattern; a user may still rotate an imported image and
  /// rescan if the physical paper itself is upside down.
  private func orderedUprightQuad(indices: [Int], candidates: [RawFiducial]) -> [Int]? {
    guard indices.count == 4 else { return nil }
    let byY = indices.sorted { candidates[$0].center.y < candidates[$1].center.y }
    let top = Array(byY.prefix(2)).sorted { candidates[$0].center.x < candidates[$1].center.x }
    let bottom = Array(byY.suffix(2)).sorted { candidates[$0].center.x < candidates[$1].center.x }
    guard top.count == 2, bottom.count == 2 else { return nil }
    let ordered = [top[0], top[1], bottom[1], bottom[0]]  // TL, TR, BR, BL
    let p = ordered.map { candidates[$0].center }
    let topSpan = max(Double(p[1].x - p[0].x), 0.0001)
    let bottomSpan = max(Double(p[2].x - p[3].x), 0.0001)
    let leftSpan = max(Double(p[3].y - p[0].y), 0.0001)
    let rightSpan = max(Double(p[2].y - p[1].y), 0.0001)
    let horizontalRatios = [
      Double(candidates[ordered[0]].normalizedSize.width) / topSpan,
      Double(candidates[ordered[1]].normalizedSize.width) / topSpan,
      Double(candidates[ordered[2]].normalizedSize.width) / bottomSpan,
      Double(candidates[ordered[3]].normalizedSize.width) / bottomSpan,
    ]
    let verticalRatios = [
      Double(candidates[ordered[0]].normalizedSize.height) / leftSpan,
      Double(candidates[ordered[3]].normalizedSize.height) / leftSpan,
      Double(candidates[ordered[1]].normalizedSize.height) / rightSpan,
      Double(candidates[ordered[2]].normalizedSize.height) / rightSpan,
    ]
    guard horizontalRatios.allSatisfy({ $0 >= 0.018 && $0 <= 0.075 }),
      verticalRatios.allSatisfy({ $0 >= 0.012 && $0 <= 0.075 })
    else { return nil }

    guard Double(p[1].x - p[0].x) >= 0.16,
      Double(p[2].x - p[3].x) >= 0.16,
      Double(p[3].y - p[0].y) >= 0.16,
      Double(p[2].y - p[1].y) >= 0.16,
      Double(polygonArea(p)) >= 0.035
    else { return nil }
    return ordered
  }

  private func deduplicated(_ values: [RawFiducial]) -> [RawFiducial] {
    var result: [RawFiducial] = []
    for candidate in values.sorted(by: { $0.priority > $1.priority }) {
      if result.contains(where: {
        hypot(Double($0.center.x - candidate.center.x), Double($0.center.y - candidate.center.y)) < 0.012
      }) { continue }
      result.append(candidate)
    }
    return Array(result.prefix(20))
  }

  private func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
      return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
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
