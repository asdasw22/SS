import CoreGraphics
import Foundation

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
  // empty. Measuring raw ink therefore creates false "multiple" answers. v8 uses
  // a radial-sector coverage score inside the bubble: it ignores the outer border
  // and most of the center glyph, then asks whether darkness is distributed around
  // the interior. A real filled mark darkens nearly every sector; printed text only
  // darkens a few sectors. This is substantially more stable for phone photos,
  // JPEG compression, monitor moire and uneven lighting.
  func bubbleStatistics(in rect: CGRect) -> (fillRatio: Double, darkness: Double, contrast: Double)
  {
    let imageBounds = CGRect(x: 0, y: 0, width: width, height: height)
    let clamped = rect.standardized.intersection(imageBounds)
    guard !clamped.isNull, clamped.width >= 6, clamped.height >= 6 else { return (0, 0, 0) }

    let center = CGPoint(x: clamped.midX, y: clamped.midY)
    let radiusX = max(2.0, clamped.width * 0.50)
    let radiusY = max(2.0, clamped.height * 0.50)
    let minX = max(0, Int((center.x - radiusX).rounded(.down)))
    let maxX = min(width, Int((center.x + radiusX).rounded(.up)))
    let minY = max(0, Int((center.y - radiusY).rounded(.down)))
    let maxY = min(height, Int((center.y + radiusY).rounded(.up)))

    let expansionX = max(3, clamped.width * 0.46)
    let expansionY = max(3, clamped.height * 0.46)
    let outer = clamped.insetBy(dx: -expansionX, dy: -expansionY).intersection(imageBounds)
    let background = localBackgroundFast(around: outer, excluding: clamped)
    let adaptiveDrop = max(13.0, background * 0.060)
    let threshold = max(38, min(238, background - adaptiveDrop))

    // Hybrid evidence.  A blank bubble contains a thin circle plus one printed
    // glyph; a genuinely filled bubble contains dark mass across most of the core.
    // The old annulus-only score could miss a real mark or overreact to a letter.
    // We now fuse core occupancy, annular coverage and mean darkness.
    let sectorCount = 16
    var sectorDark = [Int](repeating: 0, count: sectorCount)
    var sectorTotal = [Int](repeating: 0, count: sectorCount)
    var coreDark = 0
    var coreTotal = 0
    var diskDark = 0
    var diskTotal = 0
    var diskValues: [Double] = []
    diskValues.reserveCapacity(max((maxX - minX) * (maxY - minY) / 2, 16))

    for y in minY..<maxY {
      for x in minX..<maxX {
        let nx = (CGFloat(x) + 0.5 - center.x) / radiusX
        let ny = (CGFloat(y) + 0.5 - center.y) / radiusY
        let r2 = nx * nx + ny * ny
        guard r2 <= 0.72 * 0.72 else { continue }

        let pixel = Double(value(x: x, y: y))
        diskValues.append(pixel)
        diskTotal += 1
        if pixel < threshold { diskDark += 1 }

        if r2 <= 0.48 * 0.48 {
          coreTotal += 1
          if pixel < threshold { coreDark += 1 }
        }

        // Mid-radius sectors verify that the darkness is distributed around the
        // bubble instead of being only a printed A/B/C/D/E stroke.
        if r2 >= 0.20 * 0.20 && r2 <= 0.68 * 0.68 {
          var angle = atan2(ny, nx) + .pi
          if angle < 0 { angle += .pi * 2 }
          let normalizedAngle = min(0.999_999, max(0, angle / (.pi * 2)))
          let sector = min(sectorCount - 1, Int(normalizedAngle * CGFloat(sectorCount)))
          sectorTotal[sector] += 1
          if pixel < threshold { sectorDark[sector] += 1 }
        }
      }
    }

    guard diskTotal >= 12, coreTotal >= 6, !diskValues.isEmpty else { return (0, 0, 0) }
    let sectorFractions = zip(sectorDark, sectorTotal).compactMap { dark, total -> Double? in
      guard total >= 2 else { return nil }
      return Double(dark) / Double(total)
    }
    guard sectorFractions.count >= 8 else { return (0, 0, 0) }

    let coreOccupancy = Double(coreDark) / Double(coreTotal)
    let diskOccupancy = Double(diskDark) / Double(diskTotal)
    let coverageMedian = percentile(sectorFractions, 0.50)
    let coverageQuarter = percentile(sectorFractions, 0.25)
    let mean = diskValues.reduce(0, +) / Double(diskValues.count)
    let lowerQuartile = percentile(diskValues, 0.25)
    let darkness = clamp((background - mean) / max(background, 100))
    let contrast = clamp((background - lowerQuartile) / 175)

    // Core occupancy carries the most weight.  This also implements the desired
    // spatial logic: each choice is a fixed geometric cell ordered A->E, so the
    // dark mass nearest the B center is evidence for B regardless of OCR text.
    let markScore = clamp(
      coreOccupancy * 0.50
        + diskOccupancy * 0.20
        + coverageMedian * 0.14
        + coverageQuarter * 0.06
        + darkness * 0.10)
    return (markScore, darkness, contrast)
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
