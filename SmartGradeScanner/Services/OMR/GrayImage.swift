import CoreGraphics
import Foundation

/// Aggregated, illumination-robust evidence measured inside one answer bubble.
///
/// A genuine pencil/pen mark is a *large contiguous dark region* that reaches the
/// outer part of the bubble and darkens every angular sector.  A printed glyph
/// (A/B/C/D/E), the printed circle outline, dust or monitor moire is thin,
/// fragmented and centered.  Fusing independent signals (adaptive occupancy, Otsu
/// occupancy, largest connected blob, sector coverage, edge reach and a
/// cross-scheme consistency gate) lets the reader trust a mark only when *all*
/// schemes agree, which is the strongest practical defence against wrong answers.
struct BubbleEvidence: Sendable {
  var fillRatio: Double
  var darkness: Double
  var contrast: Double
  var occupancy: Double
  var otsuFill: Double
  var blobFill: Double
  var blobCount: Double
  var coverage: Double
  var edgeReach: Double
  var multiConsistency: Double
}

struct GrayImage: Sendable {
  let width: Int
  let height: Int
  var pixels: [UInt8]

  init?(cgImage: CGImage) {
    width = cgImage.width
    height = cgImage.height
    pixels = []
    guard width > 0, height > 0 else { return nil }

    var values = [UInt8](repeating: 255, count: width * height)
    let colorSpace = CGColorSpaceCreateDeviceGray()
    guard
      let context = CGContext(
        data: &values,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.none.rawValue)
    else { return nil }

    context.interpolationQuality = .high
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    pixels = values
  }

  func value(x: Int, y: Int) -> UInt8 {
    guard x >= 0, y >= 0, x < width, y < height else { return 255 }
    return pixels[y * width + x]
  }

  func statistics(in rect: CGRect, inset: CGFloat = 0.18) -> (
    fillRatio: Double, darkness: Double, contrast: Double
  ) {
    let imageBounds = CGRect(x: 0, y: 0, width: width, height: height)
    let clamped = rect.standardized.intersection(imageBounds)
    guard !clamped.isNull, clamped.width >= 4, clamped.height >= 4 else { return (0, 0, 0) }

    let safeInset = min(max(inset, 0), 0.38)
    let inner = clamped.insetBy(dx: clamped.width * safeInset, dy: clamped.height * safeInset)
    guard inner.width >= 2, inner.height >= 2 else { return (0, 0, 0) }

    let innerValues = sampledValues(in: inner)
    guard !innerValues.isEmpty else { return (0, 0, 0) }
    let background = localBackground(
      around: clamped, excluding: clamped, fallbackValues: innerValues)
    return signalStatistics(values: innerValues, background: background)
  }

  // Printed bubbles contain a dark outline and a letter/digit even when they are
  // empty, so raw dark-pixel counts create false "multiple" answers. We fuse
  // several independent, illumination-robust signals (adaptive occupancy, Otsu
  // occupancy, largest connected blob, sector coverage, edge reach and a
  // cross-scheme consistency gate). A real filled mark is one large contiguous
  // blob reaching the outer part of the bubble; printed text and dust are thin,
  // fragmented and centered.
  func bubbleEvidence(in rect: CGRect) -> BubbleEvidence {
    let empty = BubbleEvidence(
      fillRatio: 0, darkness: 0, contrast: 0, occupancy: 0, otsuFill: 0,
      blobFill: 0, blobCount: 0, coverage: 0, edgeReach: 0, multiConsistency: 0)
    let imageBounds = CGRect(x: 0, y: 0, width: width, height: height)
    let clamped = rect.standardized.intersection(imageBounds)
    guard !clamped.isNull, clamped.width >= 6, clamped.height >= 6 else { return empty }

    let center = CGPoint(x: clamped.midX, y: clamped.midY)
    let radiusX = max(2.0, clamped.width * 0.50)
    let radiusY = max(2.0, clamped.height * 0.50)
    let minX = max(0, Int((center.x - radiusX).rounded(.down)))
    let maxX = min(width, Int((center.x + radiusX).rounded(.up)))
    let minY = max(0, Int((center.y - radiusY).rounded(.down)))
    let maxY = min(height, Int((center.y + radiusY).rounded(.up)))
    let gridW = max(1, maxX - minX)
    let gridH = max(1, maxY - minY)

    let expansionX = max(3, clamped.width * 0.46)
    let expansionY = max(3, clamped.height * 0.46)
    let outer = clamped.insetBy(dx: -expansionX, dy: -expansionY).intersection(imageBounds)
    let background = localBackgroundFast(around: outer, excluding: clamped)
    let bg = min(255, max(70, background))
    let adaptiveDrop = max(13.0, bg * 0.060)
    let adaptiveThreshold = max(38, min(238, bg - adaptiveDrop))

    let sectorCount = 16
    var sectorDark = [Int](repeating: 0, count: sectorCount)
    var sectorTotal = [Int](repeating: 0, count: sectorCount)
    var diskValues: [Double] = []
    diskValues.reserveCapacity(max(gridW * gridH / 2, 16))
    var coreAdaptiveDark = 0
    var coreTotal = 0
    var diskAdaptiveDark = 0
    var diskTotal = 0

    for gy in 0..<gridH {
      let y = minY + gy
      for gx in 0..<gridW {
        let x = minX + gx
        let nx = (CGFloat(x) + 0.5 - center.x) / radiusX
        let ny = (CGFloat(y) + 0.5 - center.y) / radiusY
        let r2 = nx * nx + ny * ny
        guard r2 <= 0.72 * 0.72 else { continue }
        let pixel = Double(value(x: x, y: y))
        diskValues.append(pixel)
        diskTotal += 1
        if pixel < adaptiveThreshold { diskAdaptiveDark += 1 }
        if r2 <= 0.48 * 0.48 {
          coreTotal += 1
          if pixel < adaptiveThreshold { coreAdaptiveDark += 1 }
        }
        if r2 >= 0.20 * 0.20 && r2 <= 0.68 * 0.68 {
          var angle = atan2(ny, nx) + .pi
          if angle < 0 { angle += .pi * 2 }
          let normalizedAngle = min(0.999_999, max(0, angle / (.pi * 2)))
          let sector = min(sectorCount - 1, Int(normalizedAngle * CGFloat(sectorCount)))
          sectorTotal[sector] += 1
          if pixel < adaptiveThreshold { sectorDark[sector] += 1 }
        }
      }
    }

    guard diskTotal >= 12, !diskValues.isEmpty else { return empty }
    let occupancy = Double(coreAdaptiveDark) / Double(max(coreTotal, 1))

    // Otsu bimodal threshold over the whole disk -> robust to absolute exposure.
    let otsu = otsuThreshold(diskValues)
    let otsuDark = diskValues.reduce(0) { $0 + ($1 < otsu ? 1 : 0) }
    let otsuFill = Double(otsuDark) / Double(diskTotal)

    // Binarized (inside-ellipse && dark) mask for morphological + blob analysis.
    var baseMask = [UInt8](repeating: 0, count: gridW * gridH)
    for gy in 0..<gridH {
      let y = minY + gy
      for gx in 0..<gridW {
        let nx = (CGFloat(gx + minX) + 0.5 - center.x) / radiusX
        let ny = (CGFloat(y) + 0.5 - center.y) / radiusY
        let r2 = nx * nx + ny * ny
        guard r2 <= 0.72 * 0.72 else { continue }
        if Double(value(x: gx + minX, y: y)) < otsu {
          baseMask[gy * gridW + gx] = 1
        }
      }
    }
    let blob = closedBlobStats(baseMask: baseMask, gridW: gridW, gridH: gridH, diskTotal: diskTotal)

    let sectorFractions = zip(sectorDark, sectorTotal).compactMap { dark, total -> Double? in
      guard total >= 2 else { return nil }
      return Double(dark) / Double(total)
    }
    let coverage = sectorFractions.isEmpty ? 0 : percentile(sectorFractions, 0.50)
    let coverageQuarter = sectorFractions.isEmpty ? 0 : percentile(sectorFractions, 0.25)

    // Edge reach: ink near the *outer* part of the bubble. A centered printed glyph
    // does not reach there; a real mark usually does.
    var edgeDark = 0
    var edgeTotal = 0
    for gy in 0..<gridH {
      let y = minY + gy
      for gx in 0..<gridW {
        let nx = (CGFloat(gx + minX) + 0.5 - center.x) / radiusX
        let ny = (CGFloat(y) + 0.5 - center.y) / radiusY
        let r2 = nx * nx + ny * ny
        guard r2 >= 0.50 * 0.50 && r2 <= 0.72 * 0.72 else { continue }
        edgeTotal += 1
        if Double(value(x: gx + minX, y: y)) < otsu { edgeDark += 1 }
      }
    }
    let edgeReach = edgeTotal > 0 ? Double(edgeDark) / Double(edgeTotal) : 0

    let mean = diskValues.reduce(0, +) / Double(diskValues.count)
    let lowerQuartile = percentile(diskValues, 0.25)
    let darkness = clamp((bg - mean) / max(bg, 100))
    let contrast = clamp((bg - lowerQuartile) / 175)

    // Legacy hybrid fill ratio kept for API compatibility and student-ID path.
    let fillRatio = clamp(
      occupancy * 0.50
        + (Double(diskAdaptiveDark) / Double(diskTotal)) * 0.20
        + coverage * 0.14
        + coverageQuarter * 0.06
        + darkness * 0.10)

    // Cross-scheme agreement: adaptive occupancy, Otsu occupancy and blob size
    // must all line up before a mark is trusted. Ambiguous cells score lower.
    let expectedBlob = min(1, blob.blobFill * 1.15)
    let consistency =
      (1 - abs(occupancy - otsuFill))
        * (1 - abs(min(1, otsuFill) - expectedBlob) * 0.6)
    let multiConsistency = clamp(consistency)

    return BubbleEvidence(
      fillRatio: fillRatio, darkness: darkness, contrast: contrast,
      occupancy: occupancy, otsuFill: otsuFill, blobFill: blob.blobFill,
      blobCount: blob.blobCount, coverage: coverage, edgeReach: edgeReach,
      multiConsistency: multiConsistency)
  }
/// Strict fixed-sheet measurement (FixedOMR 904×1280): analyses only the inner
  /// disk of the bubble (≈60% of the printed radius, i.e. ≈9 px on the reference)
  /// which sits well inside the printed circular frame and away from the printed
  /// A/B/C/D/E letter. An unshaded bubble therefore contributes almost no signal,
  /// while a real pencil/pen mark is measured as one contiguous, dense blob.
  func strictBubbleEvidence(in rect: CGRect) -> BubbleEvidence {
    let empty = BubbleEvidence(
      fillRatio: 0, darkness: 0, contrast: 0, occupancy: 0, otsuFill: 0,
      blobFill: 0, blobCount: 0, coverage: 0, edgeReach: 0, multiConsistency: 0)
    let imageBounds = CGRect(x: 0, y: 0, width: width, height: height)
    let clamped = rect.standardized.intersection(imageBounds)
    guard !clamped.isNull, clamped.width >= 8, clamped.height >= 8 else { return empty }

    let center = CGPoint(x: clamped.midX, y: clamped.midY)
    let radiusX = max(2.0, clamped.width * 0.50)
    let radiusY = max(2.0, clamped.height * 0.50)
    let innerScale = 0.60   // ≈9 px for a 15 px printed radius
    let coreScale = 0.30
    let minX = max(0, Int((center.x - radiusX).rounded(.down)))
    let maxX = min(width, Int((center.x + radiusX).rounded(.up)))
    let minY = max(0, Int((center.y - radiusY).rounded(.down)))
    let maxY = min(height, Int((center.y + radiusY).rounded(.up)))
    let gridW = max(1, maxX - minX)
    let gridH = max(1, maxY - minY)

    let outer = clamped
      .insetBy(dx: -clamped.width * 0.40, dy: -clamped.height * 0.40)
      .intersection(imageBounds)
    let background = localBackgroundFast(around: outer, excluding: clamped)
    let bg = min(255, max(70, background))
    let adaptiveDrop = max(13.0, bg * 0.060)
    let adaptiveThreshold = max(38, min(238, bg - adaptiveDrop))

    let sectorCount = 16
    var sectorDark = [Int](repeating: 0, count: sectorCount)
    var sectorTotal = [Int](repeating: 0, count: sectorCount)
    var diskValues: [Double] = []
    diskValues.reserveCapacity(max(gridW * gridH / 2, 16))
    var coreAdaptiveDark = 0
    var coreTotal = 0
    var diskAdaptiveDark = 0
    var diskTotal = 0

    for gy in 0..<gridH {
      let y = minY + gy
      for gx in 0..<gridW {
        let x = minX + gx
        let nx = (CGFloat(x) + 0.5 - center.x) / radiusX
        let ny = (CGFloat(y) + 0.5 - center.y) / radiusY
        let r2 = nx * nx + ny * ny
        guard r2 <= innerScale * innerScale else { continue }
        let pixel = Double(value(x: x, y: y))
        diskValues.append(pixel)
        diskTotal += 1
        if pixel < adaptiveThreshold {
          diskAdaptiveDark += 1
        }
        if r2 <= coreScale * coreScale {
          coreTotal += 1
          if pixel < adaptiveThreshold { coreAdaptiveDark += 1 }
        }
        if r2 >= coreScale * coreScale && r2 <= innerScale * innerScale {
          var angle = atan2(ny, nx) + .pi
          if angle < 0 { angle += .pi * 2 }
          let normalizedAngle = min(0.999_999, max(0, angle / (.pi * 2)))
          let sector = min(sectorCount - 1, Int(normalizedAngle * CGFloat(sectorCount)))
          sectorTotal[sector] += 1
          if pixel < adaptiveThreshold { sectorDark[sector] += 1 }
        }
      }
    }

    guard diskTotal >= 12, !diskValues.isEmpty else { return empty }
    let occupancy = Double(coreAdaptiveDark) / Double(max(coreTotal, 1))

    let otsu = otsuThreshold(diskValues)
    let otsuDark = diskValues.reduce(0) { $0 + ($1 < otsu ? 1 : 0) }
    let otsuFill = Double(otsuDark) / Double(diskTotal)

    var baseMask = [UInt8](repeating: 0, count: gridW * gridH)
    for gy in 0..<gridH {
      let y = minY + gy
      for gx in 0..<gridW {
        let nx = (CGFloat(gx + minX) + 0.5 - center.x) / radiusX
        let ny = (CGFloat(y) + 0.5 - center.y) / radiusY
        let r2 = nx * nx + ny * ny
        guard r2 <= innerScale * innerScale else { continue }
        if Double(value(x: gx + minX, y: y)) < otsu {
          baseMask[gy * gridW + gx] = 1
        }
      }
    }
    let blob = closedBlobStats(baseMask: baseMask, gridW: gridW, gridH: gridH, diskTotal: diskTotal)

    let sectorFractions = zip(sectorDark, sectorTotal).compactMap { dark, total -> Double? in
      guard total >= 2 else { return nil }
      return Double(dark) / Double(total)
    }
    let coverage = sectorFractions.isEmpty ? 0 : percentile(sectorFractions, 0.50)

    var edgeDark = 0
    var edgeTotal = 0
    for gy in 0..<gridH {
      let y = minY + gy
      for gx in 0..<gridW {
        let nx = (CGFloat(gx + minX) + 0.5 - center.x) / radiusX
        let ny = (CGFloat(y) + 0.5 - center.y) / radiusY
        let r2 = nx * nx + ny * ny
        guard r2 >= 0.40 * 0.40 && r2 <= innerScale * innerScale else { continue }
        edgeTotal += 1
        if Double(value(x: gx + minX, y: y)) < otsu { edgeDark += 1 }
      }
    }
    let edgeReach = edgeTotal > 0 ? Double(edgeDark) / Double(edgeTotal) : 0

    let mean = diskValues.reduce(0, +) / Double(diskValues.count)
    let lowerQuartile = percentile(diskValues, 0.25)
    let darkness = clamp((bg - mean) / max(bg, 100))
    let contrast = clamp((bg - lowerQuartile) / 175)

    let fillRatio = clamp(
      occupancy * 0.50
        + (Double(diskAdaptiveDark) / Double(diskTotal)) * 0.20
        + coverage * 0.14
        + darkness * 0.16)

    let expectedBlob = min(1, blob.blobFill * 1.15)
    let consistency =
      (1 - abs(occupancy - otsuFill))
        * (1 - abs(min(1, otsuFill) - expectedBlob) * 0.6)
    let multiConsistency = clamp(consistency)

    return BubbleEvidence(
      fillRatio: fillRatio, darkness: darkness, contrast: contrast,
      occupancy: occupancy, otsuFill: otsuFill, blobFill: blob.blobFill,
      blobCount: blob.blobCount, coverage: coverage, edgeReach: edgeReach,
      multiConsistency: multiConsistency)
  }

  /// Backward-compatible wrapper used by StudentIDDetector and calibration.
  func bubbleStatistics(in rect: CGRect) -> (fillRatio: Double, darkness: Double, contrast: Double)
  {
    let e = bubbleEvidence(in: rect)
    return (e.fillRatio, e.darkness, e.contrast)
  }

  private func otsuThreshold(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 128 }
    let bins = 64
    var hist = [Int](repeating: 0, count: bins)
    for value in values {
      let clampedValue = min(255, max(0, value))
      let b = min(bins - 1, Int(clampedValue) * bins / 256)
      hist[b] += 1
    }
    let total = values.count
    var sum = 0.0
    for (i, count) in hist.enumerated() { sum += Double(i) * Double(count) }
    var sumB = 0.0
    var weightB = 0
    var maxVariance = 0.0
    var bestBin = 0
    for i in 0..<bins {
      weightB += hist[i]
      if weightB == 0 { continue }
      let weightF = total - weightB
      if weightF == 0 { break }
      sumB += Double(i) * Double(hist[i])
      let meanB = sumB / Double(weightB)
      let meanF = (sum - sumB) / Double(weightF)
      let variance = Double(weightB) * Double(weightF) * (meanB - meanF) * (meanB - meanF)
      if variance > maxVariance {
        maxVariance = variance
        bestBin = i
      }
    }
    return Double(bestBin) * 256.0 / Double(bins)
  }

  private func closedBlobStats(
    baseMask: [UInt8], gridW: Int, gridH: Int, diskTotal: Int
  ) -> (blobFill: Double, blobCount: Double) {
    let closed = morphologicalClose(baseMask, w: gridW, h: gridH)
    let sizes = connectedComponentSizes(closed, w: gridW, h: gridH)
    guard diskTotal > 0 else { return (0, 0) }
    let largest = sizes.first ?? 0
    let blobFill = min(1, Double(largest) / Double(diskTotal))
    let minBlob = max(5, Int(Double(diskTotal) * 0.012))
    let significant = sizes.filter { $0 >= minBlob }.count
    // Fragmentation: many small blobs -> higher normalized blobCount (penalized).
    let blobCount = min(1, Double(significant) / 7.0)
    return (blobFill, blobCount)
  }

  private func morphologicalClose(_ input: [UInt8], w: Int, h: Int) -> [UInt8] {
    guard !input.isEmpty else { return input }
    func at(_ arr: [UInt8], _ x: Int, _ y: Int) -> UInt8 {
      guard x >= 0, y >= 0, x < w, y < h else { return 0 }
      return arr[y * w + x]
    }
    var dilated = [UInt8](repeating: 0, count: input.count)
    for y in 0..<h {
      for x in 0..<w {
        var v: UInt8 = 0
        for dy in -1...1 {
          for dx in -1...1 {
            if at(input, x + dx, y + dy) == 1 { v = 1 }
          }
        }
        dilated[y * w + x] = v
      }
    }
    var eroded = [UInt8](repeating: 0, count: input.count)
    for y in 0..<h {
      for x in 0..<w {
        var v: UInt8 = 1
        for dy in -1...1 {
          for dx in -1...1 {
            if at(dilated, x + dx, y + dy) == 0 { v = 0 }
          }
        }
        eroded[y * w + x] = v
      }
    }
    return eroded
  }

  private func connectedComponentSizes(_ mask: [UInt8], w: Int, h: Int) -> [Int] {
    let n = mask.count
    guard n > 0 else { return [] }
    var parent = Array(0..<n)
    func find(_ a: Int) -> Int {
      var root = a
      while parent[root] != root { root = parent[root] }
      var cursor = a
      while parent[cursor] != cursor {
        let next = parent[cursor]
        parent[cursor] = root
        cursor = next
      }
      return root
    }
    func union(_ a: Int, _ b: Int) {
      let ra = find(a)
      let rb = find(b)
      if ra != rb { parent[ra] = rb }
    }
    for y in 0..<h {
      for x in 0..<w {
        let i = y * w + x
        guard mask[i] == 1 else { continue }
        if x + 1 < w, mask[i + 1] == 1 { union(i, i + 1) }
        if y + 1 < h, mask[i + w] == 1 { union(i, i + w) }
      }
    }
    var counts: [Int: Int] = [:]
    for i in 0..<n where mask[i] == 1 {
      counts[find(i), default: 0] += 1
    }
    return counts.values.sorted(by: >)
  }

  private func localBackgroundFast(around outerRect: CGRect, excluding excludedRect: CGRect) -> Double {
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    let outer = outerRect.intersection(bounds)
    guard !outer.isNull else { return 235 }
    let minX = max(0, Int(outer.minX.rounded(.down)))
    let maxX = min(width, Int(outer.maxX.rounded(.up)))
    let minY = max(0, Int(outer.minY.rounded(.down)))
    let maxY = min(height, Int(outer.maxY.rounded(.up)))
    var values: [Double] = []
    values.reserveCapacity(max((maxX - minX) * (maxY - minY) / 3, 12))
    for y in minY..<maxY {
      for x in minX..<maxX {
        let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
        if !excludedRect.contains(point) { values.append(Double(value(x: x, y: y))) }
      }
    }
    return values.count >= 8 ? percentile(values, 0.82) : 235
  }

  // Solid registration squares must be dark in their corners. Marker search runs
  // thousands of probes, so this intentionally uses O(n) means/counts rather than
  // percentile sorting. This keeps multi-candidate phone scans responsive.
  func markerStatistics(in rect: CGRect) -> (
    score: Double, contrast: Double, fillRatio: Double, cornerFill: Double
  ) {
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    let clamped = rect.standardized.intersection(bounds)
    guard !clamped.isNull, clamped.width >= 5, clamped.height >= 5 else { return (0, 0, 0, 0) }

    let inner = clamped.insetBy(dx: clamped.width * 0.05, dy: clamped.height * 0.05)
    let values = sampledValues(in: inner)
    guard values.count >= 12 else { return (0, 0, 0, 0) }

    let mean = values.reduce(0, +) / Double(values.count)
    let fillRatio = Double(values.filter { $0 < 155 }.count) / Double(values.count)
    let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
    let uniformity = clamp(1 - sqrt(max(0, variance)) / 105)

    let expansionX = max(3, clamped.width * 0.34)
    let expansionY = max(3, clamped.height * 0.34)
    let outer = clamped.insetBy(dx: -expansionX, dy: -expansionY).intersection(bounds)
    var backgroundSum = 0.0
    var backgroundCount = 0
    if !outer.isNull {
      let minX = max(0, Int(outer.minX.rounded(.down)))
      let maxX = min(width, Int(outer.maxX.rounded(.up)))
      let minY = max(0, Int(outer.minY.rounded(.down)))
      let maxY = min(height, Int(outer.maxY.rounded(.up)))
      let strideStep = max(1, Int(min(clamped.width, clamped.height) / 9))
      for y in stride(from: minY, to: maxY, by: strideStep) {
        for x in stride(from: minX, to: maxX, by: strideStep) {
          let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
          if !clamped.contains(point) {
            backgroundSum += Double(value(x: x, y: y))
            backgroundCount += 1
          }
        }
      }
    }
    let background = backgroundCount > 0 ? backgroundSum / Double(backgroundCount) : 230
    let contrast = clamp((background - mean) / 190)
    let darkness = clamp((background - mean) / max(background, 100))

    let cornerW = max(2, clamped.width * 0.24)
    let cornerH = max(2, clamped.height * 0.24)
    let cornerRects = [
      CGRect(x: clamped.minX, y: clamped.minY, width: cornerW, height: cornerH),
      CGRect(x: clamped.maxX - cornerW, y: clamped.minY, width: cornerW, height: cornerH),
      CGRect(x: clamped.minX, y: clamped.maxY - cornerH, width: cornerW, height: cornerH),
      CGRect(x: clamped.maxX - cornerW, y: clamped.maxY - cornerH, width: cornerW, height: cornerH),
    ]
    let cornerValues = cornerRects.flatMap { sampledValues(in: $0) }
    let cornerFill = cornerValues.isEmpty
      ? 0
      : Double(cornerValues.filter { $0 < 165 }.count) / Double(cornerValues.count)

    let score = clamp(
      fillRatio * 0.39
        + darkness * 0.19
        + contrast * 0.10
        + cornerFill * 0.32
    ) * (0.76 + uniformity * 0.24)

    return (score, contrast, fillRatio, cornerFill)
  }

  func lightFraction(in rect: CGRect, threshold: UInt8 = 150, step: Int = 3) -> Double {
    let clamped = rect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
    guard !clamped.isNull else { return 0 }
    let minX = max(0, Int(clamped.minX))
    let maxX = min(width, Int(clamped.maxX))
    let minY = max(0, Int(clamped.minY))
    let maxY = min(height, Int(clamped.maxY))
    var light = 0
    var count = 0
    for y in stride(from: minY, to: maxY, by: max(step, 1)) {
      for x in stride(from: minX, to: maxX, by: max(step, 1)) {
        count += 1
        if value(x: x, y: y) >= threshold { light += 1 }
      }
    }
    return Double(light) / Double(max(count, 1))
  }

  private func signalStatistics(values: [Double], background rawBackground: Double) -> (
    fillRatio: Double, darkness: Double, contrast: Double
  ) {
    guard !values.isEmpty else { return (0, 0, 0) }
    let background = min(255, max(70, rawBackground))
    let adaptiveDrop = max(18.0, background * 0.085)
    let adaptiveThreshold = max(35, min(235, background - adaptiveDrop))
    let darkCount = values.reduce(into: 0) { count, pixel in
      if pixel < adaptiveThreshold { count += 1 }
    }
    let fillRatio = Double(darkCount) / Double(values.count)
    let mean = values.reduce(0, +) / Double(values.count)
    let lowerQuartile = percentile(values, 0.25)
    let darkness = clamp((background - mean) / max(background, 90))
    let contrast = clamp((background - lowerQuartile) / 180)
    return (fillRatio, darkness, contrast)
  }

  private func localBackground(
    around outerRect: CGRect,
    excluding excludedRect: CGRect,
    fallbackValues: [Double]
  ) -> Double {
    let bounds = CGRect(x: 0, y: 0, width: width, height: height)
    let outer = outerRect.intersection(bounds)
    var values: [Double] = []
    if !outer.isNull {
      let minX = max(0, Int(outer.minX.rounded(.down)))
      let maxX = min(width, Int(outer.maxX.rounded(.up)))
      let minY = max(0, Int(outer.minY.rounded(.down)))
      let maxY = min(height, Int(outer.maxY.rounded(.up)))
      values.reserveCapacity(max((maxX - minX) * (maxY - minY) / 3, 16))
      for y in minY..<maxY {
        for x in minX..<maxX {
          let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
          if !excludedRect.contains(point) {
            values.append(Double(value(x: x, y: y)))
          }
        }
      }
    }
    if values.count >= 8 { return percentile(values, 0.78) }
    return percentile(fallbackValues, 0.90)
  }

  private func sampledValues(in rect: CGRect) -> [Double] {
    guard !rect.isNull, rect.width > 0, rect.height > 0 else { return [] }
    let minX = max(0, Int(rect.minX.rounded(.up)))
    let maxX = min(width, Int(rect.maxX.rounded(.down)))
    let minY = max(0, Int(rect.minY.rounded(.up)))
    let maxY = min(height, Int(rect.maxY.rounded(.down)))
    guard minX < maxX, minY < maxY else { return [] }

    var result: [Double] = []
    result.reserveCapacity((maxX - minX) * (maxY - minY))
    for y in minY..<maxY {
      for x in minX..<maxX {
        result.append(Double(value(x: x, y: y)))
      }
    }
    return result
  }

  private func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return 255 }
    let sorted = values.sorted()
    let position = min(max(p, 0), 1) * Double(sorted.count - 1)
    let lower = Int(position.rounded(.down))
    let upper = Int(position.rounded(.up))
    if lower == upper { return sorted[lower] }
    let fraction = position - Double(lower)
    return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
  }

  private func clamp(_ value: Double) -> Double {
    min(1, max(0, value))
  }
}
