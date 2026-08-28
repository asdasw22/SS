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

    guard localQuality >= 0.18 else {
      return ([best.choice], .invalidRegion, min(0.25, localQuality))
    }

    let separation = max(profile.filledCenter - profile.blankCenter, 0.10)
    let normalizedStrength = min(1, max(0, (best.fillRatio - profile.blankCenter) / separation))

    if best.fillRatio < profile.weakBoundary {
      let blankGap = max(0, profile.weakBoundary - best.fillRatio)
      let confidence = min(0.99, max(0.55, 0.67 + blankGap * 0.85)) * max(0.62, localQuality)
      return ([], .empty, confidence)
    }

    if best.fillRatio < profile.decisionBoundary {
      let confidence = min(
        0.64, max(0.28, localQuality * 0.52 + normalizedStrength * 0.28 + margin * 0.30))
      return ([best.choice], .weak, confidence)
    }

    // v6: never call a row "multiple" merely because two printed glyphs cross the
    // global threshold. Multiple marks must be both strong AND close to each other.
    // A truly filled bubble on the reference sheet is normally much darker than
    // every blank A/B/C/D/E circle, so a large margin means one clear answer.
    if let second {
      let multipleMargin = max(0.075, min(0.18, profile.minimumSelectionMargin * 1.10))
      let relativeStrength = secondSignal / max(best.fillRatio, 0.001)
      let bothStrong = secondSignal >= profile.decisionBoundary
      let nearlyTied = margin <= multipleMargin || relativeStrength >= 0.88
      if bothStrong && nearlyTied && second.confidence >= 0.18 {
        let selected = ordered.filter {
          $0.fillRatio >= profile.decisionBoundary
            && best.fillRatio - $0.fillRatio <= multipleMargin
            && $0.confidence >= 0.18
        }.map(\.choice)
        if selected.count >= 2 {
          let confidence = min(0.82, max(0.42, localQuality * 0.54 + relativeStrength * 0.20))
          return (selected, .multiple, confidence)
        }
      }
    }

    if margin < profile.minimumSelectionMargin {
      return (
        [best.choice], .uncertain,
        min(0.72, max(0.34, localQuality * 0.58 + normalizedStrength * 0.14 + margin * 0.40))
      )
    }

    let boundaryDistance = max(0, best.fillRatio - profile.decisionBoundary)
    let confidence = min(
      0.997,
      max(
        0.05,
        0.48
          + margin * 0.82
          + boundaryDistance * 0.40
          + normalizedStrength * 0.15
          + localQuality * 0.12))
    return ([best.choice], confidence < 0.70 ? .uncertain : .selected, confidence)
  }
}
