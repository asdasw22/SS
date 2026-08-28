import CoreGraphics
import Foundation

struct StudentIDDetector: Sendable {
  func signalSamples(
    definition: StudentIDDefinition,
    in image: CGImage,
    transform: AlignmentTransform = .identity
  ) -> [Double] {
    guard definition.hasValidGeometry,
      let gray = GrayImage(cgImage: image)
    else { return [] }
    return definition.columns.flatMap { column in
      definition.digitRows.compactMap { row in
        signal(column: column, row: row, gray: gray, transform: transform)?.signal
      }
    }
  }

  func detect(
    definition: StudentIDDefinition,
    in image: CGImage,
    profile: CalibrationProfile,
    transform: AlignmentTransform = .identity
  ) -> (value: String?, confidence: Double, warning: String?) {
    guard definition.hasValidGeometry,
      let gray = GrayImage(cgImage: image)
    else {
      return (nil, 0, "Student ID grid is not configured correctly.")
    }

    let transformedRegion = transform.apply(definition.region)
    guard !transformedRegion.isNull,
      transformedRegion.minX >= -0.02,
      transformedRegion.minY >= -0.02,
      transformedRegion.maxX <= 1.02,
      transformedRegion.maxY <= 1.02
    else {
      return (nil, 0, "Student ID region is outside the aligned sheet.")
    }

    var digits = ""
    var columnConfidences: [Double] = []
    columnConfidences.reserveCapacity(definition.columns.count)

    for (columnIndex, column) in definition.columns.enumerated() {
      let candidates = definition.digitRows.enumerated().compactMap {
        index, row -> (digit: Int, signal: Double, contrast: Double)? in
        guard let value = signal(column: column, row: row, gray: gray, transform: transform) else {
          return nil
        }
        return (index, value.signal, value.contrast)
      }.sorted { $0.signal > $1.signal }

      guard candidates.count == 10, let best = candidates.first else {
        return (nil, 0, "Student ID column \(columnIndex + 1) could not be read.")
      }

      let second = candidates.dropFirst().first?.signal ?? 0
      let margin = best.signal - second
      let minimumMargin = max(0.10, profile.minimumSelectionMargin * 0.90)
      let minimumSignal = max(profile.decisionBoundary, profile.weakBoundary + 0.045)

      guard best.signal >= minimumSignal,
        margin >= minimumMargin,
        best.contrast >= max(0.045, profile.minimumLocalContrast)
      else {
        return (
          nil,
          max(0.18, min(0.55, margin + 0.22)),
          "Student ID column \(columnIndex + 1) is unclear. Review the ID manually or retake the sheet."
        )
      }

      let relativeSecond = second / max(best.signal, 0.001)
      let trueMultiple = second >= profile.decisionBoundary
        && (margin < max(0.095, minimumMargin * 1.05) || relativeSecond >= 0.89)
      if trueMultiple {
        return (nil, 0.30, "More than one digit is marked in Student ID column \(columnIndex + 1).")
      }

      digits.append(String(best.digit))
      let signalStrength = max(
        0, (best.signal - profile.decisionBoundary) / max(1 - profile.decisionBoundary, 0.05))
      let digitConfidence = min(
        1,
        max(
          0.10,
          0.40
            + margin * 0.78
            + signalStrength * 0.27
            + best.contrast * 0.12))
      columnConfidences.append(digitConfidence)
    }

    guard digits.count == definition.columns.count else {
      return (nil, 0, "Student ID is incomplete.")
    }

    let confidence = columnConfidences.reduce(0, +) / Double(max(columnConfidences.count, 1))
    let value = definition.prefix + digits
    guard value.allSatisfy(\.isNumber) else {
      return (nil, confidence * 0.5, "Student ID contains an invalid character.")
    }
    if confidence < 0.66 {
      return (value, confidence, "Student ID confidence is borderline. Verify it before saving.")
    }
    return (value, confidence, nil)
  }

  func debugCells(
    definition: StudentIDDefinition,
    in image: CGImage,
    transform: AlignmentTransform = .identity
  ) -> [OMRDebugIDCell] {
    guard definition.hasValidGeometry,
      let gray = GrayImage(cgImage: image)
    else { return [] }
    var cells: [OMRDebugIDCell] = []
    for (columnIndex, column) in definition.columns.enumerated() {
      for (digit, row) in definition.digitRows.enumerated() {
        let cell = NormalizedRect(
          x: column.x,
          y: row.y,
          width: column.width,
          height: row.height)
        guard let measured = signal(column: column, row: row, gray: gray, transform: transform)
        else { continue }
        let transformed = transform.apply(cell)
        cells.append(
          OMRDebugIDCell(
            column: columnIndex,
            digit: digit,
            rect: NormalizedRect(cgRect: transformed),
            signal: measured.signal))
      }
    }
    return cells
  }

  private func signal(
    column: NormalizedRect,
    row: NormalizedRect,
    gray: GrayImage,
    transform: AlignmentTransform
  ) -> (signal: Double, contrast: Double)? {
    let cell = NormalizedRect(
      x: column.x,
      y: row.y,
      width: column.width,
      height: row.height)
    let transformed = transform.apply(cell)
    guard !transformed.isNull,
      transformed.midX >= 0, transformed.midX <= 1,
      transformed.midY >= 0, transformed.midY <= 1,
      transformed.width > 0.002, transformed.height > 0.002
    else { return nil }

    let size = CGSize(width: gray.width, height: gray.height)
    let pixelRect = CGRect(
      x: transformed.minX * size.width,
      y: transformed.minY * size.height,
      width: transformed.width * size.width,
      height: transformed.height * size.height)
    let stats = gray.bubbleStatistics(in: pixelRect)
    let signal = min(1, max(0, stats.fillRatio * 0.76 + stats.darkness * 0.24))
    return (signal, stats.contrast)
  }
}
