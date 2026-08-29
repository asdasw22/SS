import Foundation

struct BubbleClassifier: Sendable {
  func classify(
    measurements: [BubbleMeasurement],
    profile: CalibrationProfile
  ) -> (choices: [AnswerChoice], status: ResponseStatus, confidence: Double) {
    guard measurements.count >= 2 else { return ([], .invalidRegion, 0) }
    let ordered = measurements.sorted { $0.fillRatio > $1.fillRatio }
    guard let best = ordered.first else { return ([], .invalidRegion, 0) }
    let second = ordered.dropFirst().first
    let secondSignal = second?.fillRatio ?? 0
    let margin = best.fillRatio - secondSignal
    let localQuality = min(1, max(0, best.confidence))

    guard localQuality >= 0.14 else {
      return ([best.choice], .invalidRegion, min(0.25, localQuality))
    }

    // Robust mobile OMR needs both a global threshold and a row-local comparison.
    // A monitor, shadow, yellow paper, or uneven lighting can shift every bubble in
    // one row together. The filled bubble still remains an outlier relative to the
    // other bubbles in that same row.
    let blankSignals = ordered.dropFirst().map(\.fillRatio).sorted()
    let rowBaseline = median(blankSignals)
    let rowLift = best.fillRatio - rowBaseline
    let secondLift = secondSignal - rowBaseline
    let separation = max(profile.filledCenter - profile.blankCenter, 0.10)
    let relativeLiftNeeded = max(0.075, min(0.20, separation * 0.22))
    let strongRelative = rowLift >= relativeLiftNeeded && margin >= 0.045
    let normalizedStrength = min(1, max(0, (best.fillRatio - profile.blankCenter) / separation))

    if best.fillRatio < profile.weakBoundary && !strongRelative {
      let blankGap = max(0, profile.weakBoundary - best.fillRatio)
      let confidence = min(0.98, max(0.50, 0.64 + blankGap * 0.70)) * max(0.60, localQuality)
      return ([], .empty, confidence)
    }

    let absoluteStrong = best.fillRatio >= profile.decisionBoundary
    if !absoluteStrong && !strongRelative {
      let confidence = min(
        0.66,
        max(0.26, localQuality * 0.48 + normalizedStrength * 0.24 + rowLift * 0.72 + margin * 0.24))
      return ([best.choice], .weak, confidence)
    }

    if let second {
      let multipleMargin = max(0.055, min(0.15, profile.minimumSelectionMargin * 0.90))
      let relativeStrength = secondSignal / max(best.fillRatio, 0.001)
      let secondClearlyMarked =
        secondSignal >= profile.decisionBoundary
        || secondLift >= relativeLiftNeeded * 0.82
      let nearlyTied = margin <= multipleMargin || relativeStrength >= 0.90
      if secondClearlyMarked && nearlyTied && second.confidence >= 0.14 {
        let selected = ordered.filter { item in
          let lift = item.fillRatio - rowBaseline
          return item.confidence >= 0.14
            && (item.fillRatio >= profile.decisionBoundary || lift >= relativeLiftNeeded * 0.82)
            && best.fillRatio - item.fillRatio <= multipleMargin
        }.map(\.choice)
        if selected.count >= 2 {
          let confidence = min(0.86, max(0.42, localQuality * 0.50 + relativeStrength * 0.22 + rowLift * 0.35))
          return (selected, .multiple, confidence)
        }
      }
    }

    let requiredMargin = max(0.045, profile.minimumSelectionMargin * 0.58)
    if margin < requiredMargin && rowLift < relativeLiftNeeded * 1.45 {
      return (
        [best.choice], .uncertain,
        min(0.74, max(0.34, localQuality * 0.56 + normalizedStrength * 0.13 + rowLift * 0.55))
      )
    }

    let boundaryDistance = max(0, best.fillRatio - profile.decisionBoundary)
    let relativeScore = min(1, rowLift / max(relativeLiftNeeded * 1.8, 0.10))
    let confidence = min(
      0.997,
      max(
        0.05,
        0.46
          + margin * 0.72
          + boundaryDistance * 0.28
          + normalizedStrength * 0.10
          + relativeScore * 0.20
          + localQuality * 0.11))
    return ([best.choice], confidence < 0.66 ? .uncertain : .selected, confidence)
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
}
