import Foundation

/// Row-local OMR classifier.
///
/// The important signal is not an absolute amount of black ink. Printed glyphs,
/// camera exposure and paper color move all bubbles together. We therefore rank the
/// bubbles inside one question, estimate the blank population from the lower values,
/// and use the largest jump/outlier as the mark. This follows the same principle used
/// by mature OMR systems that compare local bubble gaps before falling back to a
/// template-wide threshold.
struct BubbleClassifier: Sendable {
  func classify(
    measurements: [BubbleMeasurement],
    profile: CalibrationProfile
  ) -> (choices: [AnswerChoice], status: ResponseStatus, confidence: Double) {
    let usable = measurements.filter { $0.confidence >= 0.10 && $0.fillRatio.isFinite }
    guard usable.count >= 2 else { return ([], .invalidRegion, 0) }

    let ordered = usable.sorted { $0.fillRatio > $1.fillRatio }
    guard let best = ordered.first else { return ([], .invalidRegion, 0) }
    guard best.confidence >= 0.18 else {
      return ([best.choice], .uncertain, min(0.30, max(0.12, best.confidence)))
    }
    let second = ordered.dropFirst().first
    let secondSignal = second?.fillRatio ?? 0

    // Use the lower 60-75% of the row as the blank population. With four or five
    // choices this deliberately excludes the strongest one (and often the second).
    let ascending = usable.map(\.fillRatio).sorted()
    let blankCount = max(1, min(ascending.count - 1, Int(Double(ascending.count) * 0.65)))
    let blankPopulation = Array(ascending.prefix(blankCount))
    let baseline = median(blankPopulation)
    let mad = median(blankPopulation.map { abs($0 - baseline) })
    let noise = max(0.018, mad * 1.4826)

    let bestLift = best.fillRatio - baseline
    let secondLift = secondSignal - baseline
    let margin = best.fillRatio - secondSignal

    let globalSeparation = max(0.20, profile.filledCenter - profile.blankCenter)
    let strongLift = max(0.16, min(0.38, globalSeparation * 0.30), noise * 3.2)
    let weakLift = max(0.075, strongLift * 0.48, noise * 2.0)
    let strongMargin = max(0.075, min(0.20, profile.minimumSelectionMargin * 0.72), noise * 1.8)

    let absoluteStrong = best.fillRatio >= profile.decisionBoundary
    let localStrong = bestLift >= strongLift
      && margin >= strongMargin
      && best.fillRatio >= max(0.38, profile.weakBoundary)
    let localWeak = bestLift >= weakLift && margin >= max(0.035, noise)

    // A true multiple response has two independently strong, nearly filled bubbles.
    // Do not call "multiple" just because printed letters make the runner-up dark.
    if second != nil {
      let secondStrong =
        secondSignal >= profile.decisionBoundary
        || secondLift >= max(strongLift * 0.88, noise * 3.0)
      let similarity = secondSignal / max(best.fillRatio, 0.001)
      let nearlyEqual = similarity >= 0.78 && margin <= max(0.18, strongMargin * 1.75)
      if secondStrong && nearlyEqual {
        let selected = ordered.filter { item in
          let lift = item.fillRatio - baseline
          let ratio = item.fillRatio / max(best.fillRatio, 0.001)
          return item.confidence >= 0.10
            && (item.fillRatio >= profile.decisionBoundary || lift >= strongLift * 0.88)
            && ratio >= 0.76
        }.map(\.choice)
        if selected.count >= 2 {
          let confidence = min(0.96, max(0.58, 0.62 + min(bestLift, secondLift) * 0.34))
          return (selected, .multiple, confidence)
        }
      }
    }

    if absoluteStrong || localStrong {
      let liftScore = min(1, bestLift / max(strongLift * 1.55, 0.20))
      let marginScore = min(1, margin / max(strongMargin * 1.55, 0.10))
      let quality = min(1, max(0, best.confidence))
      let confidence = min(0.999, 0.68 + liftScore * 0.17 + marginScore * 0.10 + quality * 0.05)
      return ([best.choice], .selected, confidence)
    }

    // No meaningful jump over the row baseline means the row is blank. The absolute
    // weak boundary is only a secondary guard because exposure can shift a full row.
    if bestLift < weakLift && best.fillRatio < profile.weakBoundary {
      let blankConfidence = min(0.98, max(0.60, 0.78 - bestLift * 0.9 + margin * 0.15))
      return ([], .empty, blankConfidence)
    }

    if localWeak {
      let confidence = min(0.72, max(0.36, 0.40 + bestLift * 0.55 + margin * 0.45))
      return ([best.choice], .weak, confidence)
    }

    // Ambiguous rather than invented. This is intentionally conservative.
    let confidence = min(0.66, max(0.28, 0.33 + bestLift * 0.42 + margin * 0.38))
    return ([best.choice], .uncertain, confidence)
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
