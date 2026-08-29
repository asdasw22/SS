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

  // The answer sheet prints A/B/C/D/E or 0-9 inside every bubble. Measuring the
  // center therefore makes an empty bubble look dark. v6 measures an elliptical
  // ring around the printed glyph and only gives a small weight to the center.
  // A filled bubble stays dark across the ring, while a blank bubble stays light.
  func bubbleStatistics(in rect: CGRect) -> (fillRatio: Double, darkness: Double, contrast: Double)
  {
    let imageBounds = CGRect(x: 0, y: 0, width: width, height: height)
    let clamped = rect.standardized.intersection(imageBounds)
    guard !clamped.isNull, clamped.width >= 6, clamped.height >= 6 else { return (0, 0, 0) }

    let center = CGPoint(x: clamped.midX, y: clamped.midY)
    let radiusX = max(2.0, clamped.width * 0.47)
    let radiusY = max(2.0, clamped.height * 0.47)
    let minX = max(0, Int((center.x - radiusX).rounded(.down)))
    let maxX = min(width, Int((center.x + radiusX).rounded(.up)))
    let minY = max(0, Int((center.y - radiusY).rounded(.down)))
    let maxY = min(height, Int((center.y + radiusY).rounded(.up)))

    var ringValues: [Double] = []
    var coreValues: [Double] = []
    ringValues.reserveCapacity(max((maxX - minX) * (maxY - minY) / 2, 16))
    coreValues.reserveCapacity(max((maxX - minX) * (maxY - minY) / 6, 8))

    for y in minY..<maxY {
      for x in minX..<maxX {
        let nx = (CGFloat(x) + 0.5 - center.x) / radiusX
        let ny = (CGFloat(y) + 0.5 - center.y) / radiusY
        let r2 = nx * nx + ny * ny
        if r2 >= 0.18 && r2 <= 0.72 {
          ringValues.append(Double(value(x: x, y: y)))
        } else if r2 < 0.18 {
          coreValues.append(Double(value(x: x, y: y)))
        }
      }
    }

    guard ringValues.count >= 8 else { return (0, 0, 0) }
    let expansionX = max(3, clamped.width * 0.38)
    let expansionY = max(3, clamped.height * 0.38)
    let outer = clamped.insetBy(dx: -expansionX, dy: -expansionY).intersection(imageBounds)
    let fallback = ringValues + coreValues
    let background = localBackground(around: outer, excluding: clamped, fallbackValues: fallback)

    let ring = signalStatistics(values: ringValues, background: background)
    let core = coreValues.count >= 6
      ? signalStatistics(values: coreValues, background: background)
      : ring

    return (
      fillRatio: clamp(ring.fillRatio * 0.86 + core.fillRatio * 0.14),
      darkness: clamp(ring.darkness * 0.86 + core.darkness * 0.14),
      contrast: clamp(max(ring.contrast, core.contrast * 0.40))
    )
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
