import CoreGraphics
import Foundation

// =====================================================================
// Strict registration (FixedOMR-904x1280-Strict-v10)
// ---------------------------------------------------------------------
// Professional marker-based registration for the fixed sheet:
//   raw photo
//     -> enhanced grayscale (CLAHE)
//     -> adaptive threshold + 3x3 morphological closing
//     -> solid-square candidate discovery (connected components)
//     -> order-independent constellation matching (RANSAC-style quad
//        enumeration + least-squares homography refinement)
//     -> homography warp DIRECTLY onto the canonical 904x1280 canvas
//     -> post-warp marker validation (residuals measured on the
//        canonical image, in canonical pixels)
//     -> confidence model (0..1) instead of raw error thresholds
//
// Recovery levels (never reject while a level can still register):
//   full             >= 6 of 8 squares matched (homography from all)
//   fourCorner       the 4 outer squares matched (corner homography)
//   boundaryFallback page-rectangle detection + fixed template geometry
//
// Coordinate conventions (do not mix these up):
//   * CGImage / GrayImage rasters: TOP-LEFT origin, y grows downward.
//   * Template canonical space: TOP-LEFT origin, 904x1280 pixels.
//   * Vision / CoreImage normalized coords: BOTTOM-LEFT origin; the
//     conversion happens only at the DetectedDocument / CIFilter edges.
// =====================================================================

/// One validated correspondence between a canonical template marker and the
/// re-detected marker on the canonical image. All coordinates are canonical
/// 904x1280 pixels with a TOP-LEFT origin.
struct CanonicalMarkerMatch: Sendable {
  let expectedCenter: CGPoint
  let detectedCenter: CGPoint
  let dx: CGFloat
  let dy: CGFloat
  let distanceError: CGFloat
  let confidence: Double
}

enum RegistrationLevel: String, Codable, Sendable {
  case full
  case fourCorner
  case boundaryFallback
}

struct StrictRegistrationReport: Sendable {
  let level: RegistrationLevel
  let matches: [CanonicalMarkerMatch]
  let meanRegistrationError: Double   // canonical px, measured post-warp
  let maxRegistrationError: Double    // canonical px, measured post-warp
  let registrationConfidence: Double  // 0..1
  let expectedMarkerCount: Int
}

struct OMRAlignmentDiagnostics: Codable, Sendable {
  struct DiagnosticMatch: Codable, Sendable {
    var expectedX: Double = 0
    var expectedY: Double = 0
    var detectedX: Double = 0
    var detectedY: Double = 0
    var dx: Double = 0
    var dy: Double = 0
    var distanceError: Double = 0
  }
  var level: String
  var detectedMarkerCount: Int
  var expectedMarkerCount: Int
  var matches: [DiagnosticMatch]
  var meanRegistrationError: Double
  var maxRegistrationError: Double
  var registrationConfidence: Double
  var message: String
  var createdAt: Date
}

struct StrictRegistrationError: Error, Sendable {
  let message: String
  let diagnostics: OMRAlignmentDiagnostics
  let original: CGImage?
  let warpedCanonical: CGImage?
}

typealias OMRDiagnosticsSink = @Sendable (
  _ diagnostics: OMRAlignmentDiagnostics,
  _ original: CGImage?,
  _ warpedCanonical: CGImage?
) -> Void

/// Persists alignment diagnostics (original photo, warped canonical image,
/// per-marker JSON) so failed registrations can be diagnosed visually.
enum AlignmentDebugStore {
  static func save(
    _ diagnostics: OMRAlignmentDiagnostics, original: CGImage?, warpedCanonical: CGImage?
  ) {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first?.appendingPathComponent("SmartGradeDebug/Alignment", isDirectory: true)
    guard let base else { return }
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter().string(from: diagnostics.createdAt)
      .replacingOccurrences(of: ":", with: "-")
    let folder = base.appendingPathComponent("\(stamp)-\(diagnostics.level)", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    if let original, let data = ImageRenderer.jpegData(from: original) {
      try? data.write(to: folder.appendingPathComponent("1-original.jpg"))
    }
    if let warpedCanonical, let data = ImageRenderer.jpegData(from: warpedCanonical) {
      try? data.write(to: folder.appendingPathComponent("2-warped-904x1280.jpg"))
    }
    if let data = try? JSONEncoder().encode(diagnostics) {
      try? data.write(to: folder.appendingPathComponent("3-report.json"))
    }
    trimOldFolders(at: base, keep: 10)
  }

  private static func trimOldFolders(at url: URL, keep: Int) {
    guard
      let contents = try? FileManager.default.contentsOfDirectory(
        at: url, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
    else { return }
    let directories = contents
      .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
    for stale in directories.dropFirst(keep) {
      try? FileManager.default.removeItem(at: stale)
    }
  }
}

/// Deterministic contrast/threshold preprocessing used by marker discovery:
/// CLAHE (robustness to shadows, glare and low contrast), adaptive mean
/// thresholding (uneven lighting), and 3x3 morphological closing (solidates
/// printed squares, removes speckle). Pure Swift, no GPU dependency.
enum RegistrationPreprocessor {
  /// Tile-based CLAHE with bilinear interpolation between tile mappings.
  static func clahe(
    _ pixels: inout [UInt8], width: Int, height: Int, tiles: Int = 8, clipLimit: Double = 2.5
  ) {
    guard width >= tiles, height >= tiles, !pixels.isEmpty else { return }
    let tileW = width / tiles
    let tileH = height / tiles
    var maps = [[Int]](repeating: [Int](repeating: 0, count: 256), count: tiles * tiles)
    for ty in 0..<tiles {
      for tx in 0..<tiles {
        let y0 = ty * tileH
        let x0 = tx * tileW
        let y1 = ty == tiles - 1 ? height : y0 + tileH
        let x1 = tx == tiles - 1 ? width : x0 + tileW
        let tileArea = Double(max(1, (y1 - y0) * (x1 - x0)))
        var histogram = [Int](repeating: 0, count: 256)
        for y in y0..<y1 {
          for x in x0..<x1 {
            histogram[Int(pixels[y * width + x])] += 1
          }
        }
        let limit = max(1.0, clipLimit * tileArea / 256.0)
        var excess = 0
        for i in 0..<256 where histogram[i] > Int(limit) {
          excess += histogram[i] - Int(limit)
          histogram[i] = Int(limit)
        }
        let bonus = excess / 256
        var cdf = 0
        for i in 0..<256 {
          cdf += histogram[i] + bonus
          maps[ty * tiles + tx][i] = Int((Double(cdf) / tileArea) * 255.0)
        }
      }
    }
    for y in 0..<height {
      let fy = Double(y) / Double(tileH) - 0.5
      let ty0 = min(tiles - 1, max(0, Int(floor(fy))))
      let ty1 = min(tiles - 1, ty0 + 1)
      let wy = min(1.0, max(0.0, fy - Double(ty0)))
      for x in 0..<width {
        let fx = Double(x) / Double(tileW) - 0.5
        let tx0 = min(tiles - 1, max(0, Int(floor(fx))))
        let tx1 = min(tiles - 1, tx0 + 1)
        let wx = min(1.0, max(0.0, fx - Double(tx0)))
        let value = Int(pixels[y * width + x])
        let a = Double(maps[ty0 * tiles + tx0][value])
        let b = Double(maps[ty0 * tiles + tx1][value])
        let c = Double(maps[ty1 * tiles + tx0][value])
        let d = Double(maps[ty1 * tiles + tx1][value])
        let top = a + (b - a) * wx
        let bottom = c + (d - c) * wx
        let out = top + (bottom - top) * wy
        pixels[y * width + x] = UInt8(max(0, min(255, Int(out.rounded()))))
      }
    }
  }

  /// Adaptive mean threshold via integral image: a pixel is foreground when it
  /// is darker than its local mean by `offset`. Handles shadow gradients and
  /// glare that a single global threshold cannot.
  static func adaptiveBinary(
    _ pixels: [UInt8], width: Int, height: Int, window: Int = 31, offset: UInt8 = 12
  ) -> [UInt8] {
    guard width > 0, height > 0 else { return [] }
    let half = window / 2
    var integral = [Double](repeating: 0, count: (width + 1) * (height + 1))
    for y in 0..<height {
      var rowSum = 0.0
      for x in 0..<width {
        rowSum += Double(pixels[y * width + x])
        integral[(y + 1) * (width + 1) + (x + 1)] = integral[y * (width + 1) + (x + 1)] + rowSum
      }
    }
    var binary = [UInt8](repeating: 0, count: width * height)
    let offsetD = Double(offset)
    for y in 0..<height {
      let y0 = max(0, y - half)
      let y1 = min(height - 1, y + half)
      for x in 0..<width {
        let x0 = max(0, x - half)
        let x1 = min(width - 1, x + half)
        let area = Double((x1 - x0 + 1) * (y1 - y0 + 1))
        let sum =
          integral[(y1 + 1) * (width + 1) + (x1 + 1)]
          - integral[y0 * (width + 1) + (x1 + 1)]
          - integral[(y1 + 1) * (width + 1) + x0]
          + integral[y0 * (width + 1) + x0]
        let mean = sum / area
        binary[y * width + x] = Double(pixels[y * width + x]) < mean - offsetD ? 1 : 0
      }
    }
    return binary
  }

  /// 3x3 morphological closing (dilate then erode) on a 0/1 binary image.
  static func morphologicalClose3x3(_ binary: inout [UInt8], width: Int, height: Int) {
    guard width > 2, height > 2, binary.count == width * height else { return }
    var dilated = [UInt8](repeating: 0, count: binary.count)
    for y in 0..<height {
      let y0 = max(0, y - 1)
      let y1 = min(height - 1, y + 1)
      for x in 0..<width {
        let x0 = max(0, x - 1)
        let x1 = min(width - 1, x + 1)
        var found: UInt8 = 0
        search: for ny in y0...y1 {
          let row = ny * width
          for nx in x0...x1 where binary[row + nx] == 1 {
            found = 1
            break search
          }
        }
        dilated[y * width + x] = found
      }
    }
    for y in 0..<height {
      let y0 = max(0, y - 1)
      let y1 = min(height - 1, y + 1)
      for x in 0..<width {
        let x0 = max(0, x - 1)
        let x1 = min(width - 1, x + 1)
        var all: UInt8 = 1
        search: for ny in y0...y1 {
          let row = ny * width
          for nx in x0...x1 where dilated[row + nx] == 0 {
            all = 0
            break search
          }
        }
        binary[y * width + x] = all
      }
    }
  }

  /// Builds a device-gray CGImage from an 8-bit single-channel buffer.
  static func grayCGImage(from pixels: [UInt8], width: Int, height: Int) -> CGImage? {
    guard width > 0, height > 0, pixels.count == width * height else { return nil }
    var data = pixels
    let context = CGContext(
      data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
    return context?.makeImage()
  }
}

struct MarkerCandidate: Sendable {
  let center: CGPoint           // RAW image pixels, TOP-LEFT origin
  let normalizedCenter: CGPoint // center / (rawWidth, rawHeight)
  let normalizedSize: CGSize    // bbox size / (rawWidth, rawHeight)
  let confidence: Double
}

/// Discovers solid dark square candidates on the raw photo. Deterministic:
/// CLAHE -> adaptive threshold -> closing -> connected components -> square
/// statistics. Filled answer bubbles can also pass these gates; the downstream
/// constellation matcher only accepts candidates near predicted marker
/// positions, so extra candidates are harmless.
struct MarkerCandidateLocator: Sendable {
  func candidates(in raw: CGImage) -> [MarkerCandidate] {
    let preprocessor = ImagePreprocessor()
    let working = preprocessor.resizedImage(from: raw, longEdge: 1400) ?? raw
    let workW = working.width
    let workH = working.height
    guard workW >= 120, workH >= 120, let baseGray = GrayImage(cgImage: working) else { return [] }
    var pixels = baseGray.pixels
    RegistrationPreprocessor.clahe(&pixels, width: workW, height: workH)
    guard
      let enhancedCG = RegistrationPreprocessor.grayCGImage(
        from: pixels, width: workW, height: workH),
      let enhanced = GrayImage(cgImage: enhancedCG)
    else { return [] }
    var binary = RegistrationPreprocessor.adaptiveBinary(pixels, width: workW, height: workH)
    RegistrationPreprocessor.morphologicalClose3x3(&binary, width: workW, height: workH)

    let minDimension = Double(min(workW, workH))
    let minSide = max(4, Int((minDimension * 0.0035).rounded(.down)))
    let maxSide = max(minSide + 2, Int((minDimension * 0.095).rounded(.up)))
    var visited = [UInt8](repeating: 0, count: workW * workH)
    var result: [MarkerCandidate] = []
    var queue: [Int] = []
    queue.reserveCapacity(4096)

    for y in 0..<workH {
      for x in 0..<workW {
        let seed = y * workW + x
        if visited[seed] != 0 || binary[seed] == 0 { continue }
        queue.removeAll(keepingCapacity: true)
        queue.append(seed)
        visited[seed] = 1
        var cursor = 0
        var count = 0
        var minX = x, maxX = x, minY = y, maxY = y
        while cursor < queue.count {
          let index = queue[cursor]
          cursor += 1
          let cx = index % workW
          let cy = index / workW
          count += 1
          if cx < minX { minX = cx }
          if cx > maxX { maxX = cx }
          if cy < minY { minY = cy }
          if cy > maxY { maxY = cy }
          var neighborY = max(0, cy - 1)
          while neighborY <= min(workH - 1, cy + 1) {
            var neighborX = max(0, cx - 1)
            while neighborX <= min(workW - 1, cx + 1) {
              let neighbor = neighborY * workW + neighborX
              if visited[neighbor] == 0 && binary[neighbor] == 1 {
                visited[neighbor] = 1
                queue.append(neighbor)
              }
              neighborX += 1
            }
            neighborY += 1
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
        let stats = enhanced.markerStatistics(in: rect)
        guard stats.cornerFill >= 0.34, stats.fillRatio >= 0.46,
          stats.score >= 0.38, stats.contrast >= 0.020
        else { continue }
        let shapeScore = max(0, 1 - abs(log(max(aspect, 0.001))) / 0.55)
        let confidence = min(
          1,
          max(
            0,
            stats.score * 0.50 + stats.cornerFill * 0.20 + solidity * 0.18
              + shapeScore * 0.12))
        let scale = Double(max(raw.width, raw.height)) / Double(max(workW, workH))
        let centerWork = CGPoint(x: (minX + maxX) * 0.5, y: (minY + maxY) * 0.5)
        let centerRaw = CGPoint(x: centerWork.x * scale, y: centerWork.y * scale)
        result.append(
          MarkerCandidate(
            center: centerRaw,
            normalizedCenter: CGPoint(
              x: centerRaw.x / Double(raw.width), y: centerRaw.y / Double(raw.height)),
            normalizedSize: CGSize(
              width: Double(boxWidth) * scale / Double(raw.width),
              height: Double(boxHeight) * scale / Double(raw.height)),
            confidence: confidence))
      }
    }
    // Deduplicate overlapping detections, keep the strongest 40 (quad
    // enumeration stays fast; the upright-quad gate prunes almost everything).
    var unique: [MarkerCandidate] = []
    for candidate in result.sorted(by: { $0.confidence > $1.confidence }) {
      if unique.contains(where: {
        hypot(
          Double($0.normalizedCenter.x - candidate.normalizedCenter.x),
          Double($0.normalizedCenter.y - candidate.normalizedCenter.y)) < 0.012
      }) { continue }
      unique.append(candidate)
    }
    return Array(unique.prefix(40))
  }
}

struct StrictRegistrationService: Sendable {
  // Canonical canvas of the fixed sheet (TOP-LEFT origin pixel space).
  static let canonicalWidth = 904.0
  static let canonicalHeight = 1280.0

  private let markerDetector = MarkerDetectionService()
  private let documentDetector = DocumentDetectionService()
  private let preprocessor = ImagePreprocessor()
  private let homography = HomographySolver()
  private let candidateLocator = MarkerCandidateLocator()

  struct RegistrationOutput: Sendable {
    let canonical: CGImage          // exactly 904x1280
    let report: StrictRegistrationReport
    let visionCorners: [CGPoint]    // mapped page quad, Vision bottom-left normalized (TL,TR,BR,BL)
    let pageArea: Double            // normalized to the raw frame
    let original: CGImage           // oriented raw input (for diagnostics)
    let diagnostics: OMRAlignmentDiagnostics
  }

  /// Runs the full strict registration. Throws StrictRegistrationError (with
  /// diagnostics attached) when no recovery level can produce a usable page.
  func register(
    raw: CGImage, template: TemplateDefinition, thresholds: OMRStrictThresholds
  ) throws -> RegistrationOutput {
    let expectedPx = template.markers.map {
      CGPoint(
        x: $0.expectedRect.center.x * Self.canonicalWidth,
        y: $0.expectedRect.center.y * Self.canonicalHeight)
    }
    guard expectedPx.count >= 4 else {
      throw failure(
        template: template, level: .boundaryFallback, matches: [], mean: 0, max: 0,
        confidence: 0, original: raw, warped: nil,
        message: "The template does not define enough registration squares.")
    }

    // ---- Levels 1 & 2: marker constellation on the raw photo ---------------
    let candidates = candidateLocator.candidates(in: raw)
    let constellation = matchConstellation(
      expectedPx: expectedPx, candidates: candidates,
      rawSize: CGSize(width: raw.width, height: raw.height))

    var level: RegistrationLevel?
    var pairs: [(expected: CGPoint, detected: CGPoint, confidence: Double)] = []
    if let matched = constellation {
      if matched.pairs.count >= 6 {
        level = .full
        pairs = matched.pairs.map { ($0.expected, $0.detected, $0.confidence) }
      } else if matched.pairs.count >= 4, matched.outerMatched {
        // Corner recovery: refit on the four outer markers only.
        level = .fourCorner
        pairs = matched.outerPairs.map { ($0.expected, $0.detected, $0.confidence) }
      }
    }

    guard let level else {
      return try boundaryFallbackRegistration(
        raw: raw, template: template, thresholds: thresholds, expectedPx: expectedPx)
    }
    guard
      let transform = homography.solve(
        source: pairs.map { $0.expected }, destination: pairs.map { $0.detected })
    else {
      return try boundaryFallbackRegistration(
        raw: raw, template: template, thresholds: thresholds, expectedPx: expectedPx)
    }
    guard geometryIsUpright(transform) else {
      throw failure(
        template: template, level: level, matches: [], mean: 0, max: 0, confidence: 0,
        original: raw, warped: nil,
        message:
          "The sheet appears rotated or mirrored. Retake the photo with the page upright and the black squares readable.")
    }

    // ---- Warp DIRECTLY onto the canonical canvas with the marker homography.
    // Global perspective, rotation, scale and translation are absorbed by the
    // warp; only true non-linear paper distortion remains for the confidence.
    let corners = [
      CGPoint(x: 0, y: 0),
      CGPoint(x: Self.canonicalWidth, y: 0),
      CGPoint(x: Self.canonicalWidth, y: Self.canonicalHeight),
      CGPoint(x: 0, y: Self.canonicalHeight),
    ].map { transform.apply($0) }
    guard
      let canonical = preprocessor.canonicalWarp(
        from: raw, topLeftCorners: corners,
        targetWidth: Self.canonicalWidth, targetHeight: Self.canonicalHeight)
    else {
      return try boundaryFallbackRegistration(
        raw: raw, template: template, thresholds: thresholds, expectedPx: expectedPx)
    }

    let report = makeReport(
      canonical: canonical, template: template, thresholds: thresholds, level: level)
    guard report.matches.count >= 4 else {
      throw failure(
        template: template, level: level, matches: report.matches,
        mean: report.meanRegistrationError, max: report.maxRegistrationError,
        confidence: report.registrationConfidence, original: raw, warped: canonical,
        message:
          "Only \(report.matches.count) of \(report.expectedMarkerCount) registration squares are visible after registration. Retake the photo with the full sheet visible and unobstructed.")
    }

    let normalizedCorners = corners.map {
      CGPoint(x: $0.x / Double(raw.width), y: $0.y / Double(raw.height))
    }
    let visionCorners = normalizedCorners.map { CGPoint(x: $0.x, y: 1 - $0.y) }
    let diagnostics = makeDiagnostics(
      level: level, expectedCount: report.expectedMarkerCount, matches: report.matches,
      mean: report.meanRegistrationError, max: report.maxRegistrationError,
      confidence: report.registrationConfidence,
      message:
        "registered level=\(level.rawValue) confidence=\(Int((report.registrationConfidence * 100).rounded()))% mean=\(String(format: "%.1f", report.meanRegistrationError))px")
    return RegistrationOutput(
      canonical: canonical, report: report, visionCorners: visionCorners,
      pageArea: Double(polygonArea(normalizedCorners)), original: raw,
      diagnostics: diagnostics)
  }

  // ---- Level 3: page boundary + fixed template geometry ------------------
  private func boundaryFallbackRegistration(
    raw: CGImage, template: TemplateDefinition, thresholds: OMRStrictThresholds,
    expectedPx: [CGPoint]
  ) throws -> RegistrationOutput {
    var bestCanonical: CGImage?
    var bestMatches: [CanonicalMarkerMatch] = []
    var bestVisionCorners: [CGPoint] = []
    var bestArea = 0.0
    let rawSize = CGSize(width: raw.width, height: raw.height)

    if let documents = try? documentDetector.candidates(
      in: raw, expectedAspectRatio: template.pageAspectRatio, template: template)
    {
      for document in documents.prefix(3) {
        let corners = document.normalizedCorners.map {
          CGPoint(x: $0.x * rawSize.width, y: $0.y * rawSize.height)
        }
        let corrected: CGImage?
        if document.source == .fullFrame {
          corrected = preprocessor.resizedImage(from: raw, longEdge: 1320)
        } else {
          corrected = preprocessor.correctedImage(
            from: raw, corners: corners,
            targetAspectRatio: template.pageAspectRatio, longEdge: 1320)
        }
        guard let pageImage = corrected else { continue }
        let pageQuad = [
          CGPoint(x: 0, y: 0),
          CGPoint(x: pageImage.width, y: 0),
          CGPoint(x: pageImage.width, y: pageImage.height),
          CGPoint(x: 0, y: pageImage.height),
        ]
        guard
          let canonical = preprocessor.canonicalWarp(
            from: pageImage, topLeftCorners: pageQuad,
            targetWidth: Self.canonicalWidth, targetHeight: Self.canonicalHeight)
        else { continue }
        let detected = markerDetector.detect(
          in: canonical, expected: template.markers,
          profile: template.calibration, ignoredAreas: [])
        guard detected.count >= 4 else { continue }
        if detected.count > bestMatches.count {
          bestCanonical = canonical
          bestMatches = canonicalMatches(from: detected)
          bestVisionCorners = document.normalizedCorners
          bestArea = document.area
        }
      }
    }

    guard let canonical = bestCanonical, bestMatches.count >= 4 else {
      throw failure(
        template: template, level: .boundaryFallback, matches: bestMatches,
        mean: 0, max: 0, confidence: 0, original: raw, warped: bestCanonical,
        message:
          "Registration failed: not enough printed squares were found (\(bestMatches.count) of \(expectedPx.count)) and no page boundary matched. Retake the photo: full page, upright, flat, all 8 black squares visible.")
    }
    let report = makeReport(
      canonical: canonical, template: template, thresholds: thresholds,
      level: .boundaryFallback)
    let diagnostics = makeDiagnostics(
      level: .boundaryFallback, expectedCount: report.expectedMarkerCount,
      matches: report.matches, mean: report.meanRegistrationError,
      max: report.maxRegistrationError, confidence: report.registrationConfidence,
      message:
        "registered level=boundaryFallback confidence=\(Int((report.registrationConfidence * 100).rounded()))%")
    return RegistrationOutput(
      canonical: canonical, report: report, visionCorners: bestVisionCorners,
      pageArea: bestArea, original: raw, diagnostics: diagnostics)
  }

  private func canonicalMatches(from detected: [DetectedMarker]) -> [CanonicalMarkerMatch] {
    detected.map { marker in
      let expected = CGPoint(
        x: marker.expectedCenter.x * Self.canonicalWidth,
        y: marker.expectedCenter.y * Self.canonicalHeight)
      let actual = CGPoint(
        x: marker.center.x * Self.canonicalWidth,
        y: marker.center.y * Self.canonicalHeight)
      return CanonicalMarkerMatch(
        expectedCenter: expected, detectedCenter: actual,
        dx: actual.x - expected.x, dy: actual.y - expected.y,
        distanceError: hypot(Double(actual.x - expected.x), Double(actual.y - expected.y)),
        confidence: marker.confidence)
    }
  }

  /// Post-warp validation: residuals are measured on the canonical image, in
  /// canonical pixels, and folded into one documented confidence score.
  private func makeReport(
    canonical: CGImage, template: TemplateDefinition,
    thresholds: OMRStrictThresholds, level: RegistrationLevel
  ) -> StrictRegistrationReport {
    let detected = markerDetector.detect(
      in: canonical, expected: template.markers,
      profile: template.calibration, ignoredAreas: [])
    let matches = canonicalMatches(from: detected)
    let meanError =
      matches.isEmpty ? 0 : matches.map { $0.distanceError }.reduce(0, +) / Double(matches.count)
    let maxError = matches.map { $0.distanceError }.max() ?? 0
    let coverage = Double(matches.count) / Double(max(template.markers.count, 1))
    let meanConfidence =
      matches.isEmpty ? 0 : matches.map { $0.confidence }.reduce(0, +) / Double(matches.count)
    let meanScore = max(0, 1 - meanError / max(thresholds.alignmentMeanErrorReference, 1))
    let maxScore = max(0, 1 - maxError / max(thresholds.alignmentMaxErrorReference, 1))
    var confidence =
      0.42 * meanScore + 0.20 * maxScore + 0.23 * meanConfidence + 0.15 * coverage
    if level == .boundaryFallback { confidence *= 0.92 }
    confidence = min(1, max(0, confidence))
    return StrictRegistrationReport(
      level: level, matches: matches, meanRegistrationError: meanError,
      maxRegistrationError: maxError, registrationConfidence: confidence,
      expectedMarkerCount: template.markers.count)
  }

  /// A fitted homography that flips the page (180-degree rotation or mirror)
  /// must never be graded.
  private func geometryIsUpright(_ transform: ProjectiveTransform) -> Bool {
    let topMid = transform.apply(CGPoint(x: Self.canonicalWidth / 2, y: 0))
    let bottomMid = transform.apply(CGPoint(x: Self.canonicalWidth / 2, y: Self.canonicalHeight))
    let leftMid = transform.apply(CGPoint(x: 0, y: Self.canonicalHeight / 2))
    let rightMid = transform.apply(CGPoint(x: Self.canonicalWidth, y: Self.canonicalHeight / 2))
    return topMid.y < bottomMid.y && leftMid.x < rightMid.x
  }

  private struct ConstellationMatch: Sendable {
    struct Pair: Sendable {
      let expectedIndex: Int
      let expected: CGPoint      // canonical px
      let detected: CGPoint      // raw px
      let confidence: Double
      let residual: Double       // raw px
    }
    let pairs: [Pair]
    let outerExpectedIndices: Set<Int>
    var outerMatched: Bool {
      outerExpectedIndices.isSubset(of: Set(pairs.map { $0.expectedIndex }))
    }
    var outerPairs: [Pair] {
      pairs.filter { outerExpectedIndices.contains($0.expectedIndex) }
    }
  }

  /// Order-independent robust matching between the expected marker
  /// constellation and the discovered candidates: enumerate upright candidate
  /// quads, fit a homography from the four OUTER expected markers, then assign
  /// every expected marker to its nearest candidate inside an adaptive
  /// tolerance, and refine with least-squares homography + outlier rejection.
  private func matchConstellation(
    expectedPx: [CGPoint], candidates: [MarkerCandidate], rawSize: CGSize
  ) -> ConstellationMatch? {
    guard expectedPx.count >= 4, candidates.count >= 4,
      let outer = outerIndices(expectedPx)
    else { return nil }
    let expectedOuter = outer.map { expectedPx[$0] }
    let rawW = Double(rawSize.width)
    let rawH = Double(rawSize.height)

    var best: ConstellationMatch?
    var bestScore = -Double.greatestFiniteMagnitude
    let n = candidates.count

    for a in 0..<(n - 3) {
      for b in (a + 1)..<(n - 2) {
        for c in (b + 1)..<(n - 1) {
          for d in (c + 1)..<n {
            guard
              let ordered = orderedUprightQuad(indices: [a, b, c, d], candidates: candidates)
            else { continue }
            let destinationOuter = ordered.map { candidates[$0].center }
            guard
              let initial = homography.solve(
                source: expectedOuter, destination: destinationOuter)
            else { continue }
            let pageCorners = [
              initial.apply(CGPoint(x: 0, y: 0)),
              initial.apply(CGPoint(x: Self.canonicalWidth, y: 0)),
              initial.apply(CGPoint(x: Self.canonicalWidth, y: Self.canonicalHeight)),
              initial.apply(CGPoint(x: 0, y: Self.canonicalHeight)),
            ]
            let normalizedCorners = pageCorners.map {
              CGPoint(x: $0.x / rawW, y: $0.y / rawH)
            }
            guard normalizedCorners.allSatisfy({
              $0.x >= -0.10 && $0.x <= 1.10 && $0.y >= -0.10 && $0.y <= 1.10
            }) else { continue }
            let pageArea = Double(polygonArea(normalizedCorners))
            guard pageArea >= 0.055, pageArea <= 1.10 else { continue }

            let tolerancePx =
              max(0.014, min(0.036, sqrt(pageArea) * 0.060)) * Double(min(rawW, rawH))
            var used = Set<Int>()
            var matched: [ConstellationMatch.Pair] = []
            for (expectedIndex, point) in expectedPx.enumerated() {
              let predicted = initial.apply(point)
              var nearestIndex: Int?
              var nearestDistance = Double.greatestFiniteMagnitude
              for candidateIndex in candidates.indices where !used.contains(candidateIndex) {
                let candidate = candidates[candidateIndex]
                let distance = hypot(
                  predicted.x - candidate.center.x, predicted.y - candidate.center.y)
                if distance < nearestDistance {
                  nearestDistance = distance
                  nearestIndex = candidateIndex
                }
              }
              if let nearestIndex, nearestDistance <= tolerancePx {
                used.insert(nearestIndex)
                matched.append(
                  ConstellationMatch.Pair(
                    expectedIndex: expectedIndex, expected: point,
                    detected: candidates[nearestIndex].center,
                    confidence: candidates[nearestIndex].confidence,
                    residual: nearestDistance))
              }
            }
            guard matched.count >= 4 else { continue }

            // Refine on the full correspondence set (least-squares homography),
            // dropping gross outliers between fits.
            var pairs = matched
            for _ in 0..<2 {
              guard pairs.count >= 4,
                let refined = homography.solve(
                  source: pairs.map { $0.expected }, destination: pairs.map { $0.detected })
              else { break }
              let residuals = pairs.map {
                homography.distance(refined.apply($0.expected), $0.detected)
              }
              let cutoff = max(tolerancePx * 0.8, median(residuals) * 2.2)
              let inliers = zip(pairs, residuals).filter { $1 <= cutoff }.map { $0.0 }
              guard inliers.count >= 4 else { break }
              let converged = inliers.count == pairs.count
              pairs = inliers
              if converged { break }
            }
            guard
              let final = homography.solve(
                source: pairs.map { $0.expected }, destination: pairs.map { $0.detected })
            else { continue }
            let finalResiduals = pairs.map {
              homography.distance(final.apply($0.expected), $0.detected)
            }
            let meanResidual = finalResiduals.reduce(0, +) / Double(finalResiduals.count)
            let meanConfidence = pairs.map { $0.confidence }.reduce(0, +) / Double(pairs.count)
            let coverage = Double(pairs.count) / Double(expectedPx.count)
            let score =
              Double(pairs.count) * 2.05 + meanConfidence * 0.70 + coverage * 0.80
              - (meanResidual / Double(min(rawW, rawH))) * 34.0
            if score > bestScore {
              bestScore = score
              best = ConstellationMatch(pairs: pairs, outerExpectedIndices: Set(outer))
            }
          }
        }
      }
    }
    return best
  }

  /// Expected outer marks in TL, TR, BR, BL order (x+y / x-y extremes).
  private func outerIndices(_ points: [CGPoint]) -> [Int]? {
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

  /// Orders a candidate quad assuming the printed sheet is roughly upright in
  /// the EXIF-normalized photo. This intentionally rejects 180-degree matches
  /// from a symmetric square pattern; geometryIsUpright adds the final guard.
  private func orderedUprightQuad(indices: [Int], candidates: [MarkerCandidate]) -> [Int]? {
    guard indices.count == 4 else { return nil }
    let byY = indices.sorted {
      candidates[$0].normalizedCenter.y < candidates[$1].normalizedCenter.y
    }
    let top = Array(byY.prefix(2)).sorted {
      candidates[$0].normalizedCenter.x < candidates[$1].normalizedCenter.x
    }
    let bottom = Array(byY.suffix(2)).sorted {
      candidates[$0].normalizedCenter.x < candidates[$1].normalizedCenter.x
    }
    guard top.count == 2, bottom.count == 2 else { return nil }
    let ordered = [top[0], top[1], bottom[1], bottom[0]] // TL, TR, BR, BL
    let p = ordered.map { candidates[$0].normalizedCenter }
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
    guard Double(p[1].x - p[0].x) >= 0.16, Double(p[2].x - p[3].x) >= 0.16,
      Double(p[3].y - p[0].y) >= 0.16, Double(p[2].y - p[1].y) >= 0.16,
      polygonArea(p) >= 0.035
    else { return nil }
    return ordered
  }

  private func makeDiagnostics(
    level: RegistrationLevel, expectedCount: Int, matches: [CanonicalMarkerMatch],
    mean: Double, max: Double, confidence: Double, message: String
  ) -> OMRAlignmentDiagnostics {
    OMRAlignmentDiagnostics(
      level: level.rawValue,
      detectedMarkerCount: matches.count,
      expectedMarkerCount: expectedCount,
      matches: matches.map {
        OMRAlignmentDiagnostics.DiagnosticMatch(
          expectedX: $0.expectedCenter.x, expectedY: $0.expectedCenter.y,
          detectedX: $0.detectedCenter.x, detectedY: $0.detectedCenter.y,
          dx: $0.dx, dy: $0.dy, distanceError: $0.distanceError)
      },
      meanRegistrationError: mean, maxRegistrationError: max,
      registrationConfidence: confidence, message: message, createdAt: Date())
  }

  private func failure(
    template: TemplateDefinition, level: RegistrationLevel,
    matches: [CanonicalMarkerMatch], mean: Double, max: Double, confidence: Double,
    original: CGImage?, warped: CGImage?, message: String
  ) -> StrictRegistrationError {
    StrictRegistrationError(
      message: message,
      diagnostics: makeDiagnostics(
        level: level, expectedCount: template.markers.count, matches: matches,
        mean: mean, max: max, confidence: confidence, message: message),
      original: original, warpedCanonical: warped)
  }

  private func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2)
      ? (sorted[middle - 1] + sorted[middle]) / 2
      : sorted[middle]
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
