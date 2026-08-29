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
      let blankBaseline = median(candidates.dropFirst().map(\.signal))
      let separation = max(profile.filledCenter - profile.blankCenter, 0.10)
      let relativeLiftNeeded = max(0.070, min(0.19, separation * 0.20))
      let bestLift = best.signal - blankBaseline
      let secondLift = second - blankBaseline
      let minimumMargin = max(0.050, profile.minimumSelectionMargin * 0.52)
      let absoluteStrong = best.signal >= profile.decisionBoundary
      let relativeStrong = bestLift >= relativeLiftNeeded && margin >= minimumMargin

      guard (absoluteStrong || relativeStrong),
        best.contrast >= max(0.025, profile.minimumLocalContrast * 0.65)
      else {
        return (
          nil,
          max(0.18, min(0.58, margin + bestLift + 0.16)),
          "Student ID column \(columnIndex + 1) is unclear. Review the ID manually or retake the sheet."
        )
      }

      let relativeSecond = second / max(best.signal, 0.001)
      let secondClearlyMarked = second >= profile.decisionBoundary
        || secondLift >= relativeLiftNeeded * 0.82
      let trueMultiple = secondClearlyMarked
        && (margin < max(0.060, minimumMargin * 1.10) || relativeSecond >= 0.91)
      if trueMultiple {
        return (nil, 0.30, "More than one digit is marked in Student ID column \(columnIndex + 1).")
      }

      digits.append(String(best.digit))
      let absoluteStrength = max(
        0, (best.signal - profile.decisionBoundary) / max(1 - profile.decisionBoundary, 0.05))
      let relativeStrength = min(1, max(0, bestLift / max(relativeLiftNeeded * 1.8, 0.10)))
      let signalStrength = max(absoluteStrength, relativeStrength)
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

  /// Strict fixed-sheet ID reading: every column is classified independently into
  /// digit / blank / multiple / ambiguous / unreadable. The ID is valid ONLY when
  /// every column holds exactly one provable mark. Never guesses: any uncertain
  /// column invalidates the whole ID instead of emitting the nearest digit.
  func detectStrict(
    definition: StudentIDDefinition,
    in image: CGImage,
    profile: CalibrationProfile,
    transform: AlignmentTransform = .identity
  ) -> (
    columns: [StudentIDColumnResult],
    value: String?,
    state: StudentIDResultState,
    confidence: Double
  ) {
    guard definition.hasValidGeometry, let gray = GrayImage(cgImage: image) else {
      return ([], nil, .unreadable, 0)
    }

    var results: [StudentIDColumnResult] = []
    results.reserveCapacity(definition.columns.count)
    var digits = ""
    var invalidState: StudentIDResultState?
    var invalidColumn = 0

    for (columnIndex, column) in definition.columns.enumerated() {
      let number = columnIndex + 1
      let signals = definition.digitRows.enumerated().compactMap {
        index, row -> (digit: Int, signal: Double, contrast: Double)? in
        guard let value = signal(column: column, row: row, gray: gray, transform: transform)
        else { return nil }
        return (index, value.signal, value.contrast)
      }

      guard signals.count == definition.digitRows.count,
        let best = signals.max(by: { $0.signal < $1.signal })
      else {
        results.append(
          StudentIDColumnResult(
            column: number, state: .unreadable, digit: nil,
            bestSignal: 0, secondSignal: 0, margin: 0, confidence: 0))
        if invalidState == nil { invalidState = .unreadable; invalidColumn = number }
        continue
      }

      let others = signals.filter { $0.digit != best.digit }
      let second = others.map(\.signal).max() ?? 0
      let margin = best.signal - second
      let blankBaseline = median(others.map(\.signal))
      let separation = max(profile.filledCenter - profile.blankCenter, 0.10)
      let relativeLiftNeeded = max(0.070, min(0.19, separation * 0.20))
      let bestLift = best.signal - blankBaseline
      let secondLift = second - blankBaseline
      let minimumMargin = max(0.050, profile.minimumSelectionMargin * 0.52)
      let absoluteStrong = best.signal >= profile.decisionBoundary
      let relativeStrong = bestLift >= relativeLiftNeeded && margin >= minimumMargin
      let bestProven =
        (absoluteStrong || relativeStrong)
        && best.contrast >= max(0.025, profile.minimumLocalContrast * 0.65)
      let secondProven =
        second >= profile.decisionBoundary || secondLift >= relativeLiftNeeded * 0.82

      let state: StudentIDColumnState
      let digitValue: Int?
      if bestProven && secondProven {
        state = .multiple
        digitValue = nil
      } else if bestProven {
        state = .digit
        digitValue = best.digit
      } else if bestLift >= relativeLiftNeeded * 0.55 {
        // Something is present but it cannot be proven to be a single mark.
        state = .ambiguous
        digitValue = nil
      } else {
        state = .blank
        digitValue = nil
      }

      let absoluteStrength = max(
        0, (best.signal - profile.decisionBoundary) / max(1 - profile.decisionBoundary, 0.05))
      let relativeStrength = min(1, max(0, bestLift / max(relativeLiftNeeded * 1.8, 0.10)))
      let columnConfidence =
        state == .digit
        ? min(
          1,
          max(
            0.10,
            0.40 + margin * 0.78 + max(absoluteStrength, relativeStrength) * 0.27
              + best.contrast * 0.12))
        : (state == .blank ? 0.85 : 0.20)

      results.append(
        StudentIDColumnResult(
          column: number,
          state: state,
          digit: digitValue,
          bestSignal: best.signal,
          secondSignal: second,
          margin: margin,
          confidence: columnConfidence))

      switch state {
      case .digit:
        digits.append(String(best.digit))
      case .multiple:
        invalidState = .invalidMultiple
        invalidColumn = number
      case .ambiguous:
        if invalidState == nil { invalidState = .invalidAmbiguous; invalidColumn = number }
      case .blank:
        if invalidState == nil { invalidState = .invalidBlankColumn; invalidColumn = number }
      case .unreadable:
        if invalidState == nil { invalidState = .unreadable; invalidColumn = number }
      }
    }

    if let invalid = invalidState {
      return (results, nil, invalid, 0.2)
    }
    let confidence = results.map(\.confidence).reduce(0, +) / Double(max(results.count, 1))
    return (results, definition.prefix + digits, .valid, confidence)
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

  private func median(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
      return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
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
    let evidence = gray.bubbleEvidence(in: pixelRect)
    let signal = min(
      1,
      max(0, evidence.fillRatio * 0.84 + evidence.blobFill * 0.10 + evidence.darkness * 0.06))
    return (signal, evidence.contrast)
  }
}
