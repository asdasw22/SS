import Foundation

/// Conservative row-local OMR classifier.
///
/// Every question is decoded geometrically: bubbles are ordered left-to-right and
/// mapped to A, B, C, D, E by their template positions.  OCR is never used to decide
/// an answer.  Classification fuses absolute fill evidence with the *relative jump*
/// inside the row.  This makes a clear mark win even when a phone camera changes the
/// overall exposure, while blank rows remain blank because all five cells look alike.
struct BubbleClassifier: Sendable {
  func classify(
    measurements: [BubbleMeasurement],
    profile: CalibrationProfile
  ) -> (choices: [AnswerChoice], status: ResponseStatus, confidence: Double) {
    let usable = measurements
      .filter { $0.confidence >= 0.14 && $0.fillRatio.isFinite }
      .sorted { $0.choice.rank < $1.choice.rank }
    guard usable.count >= 2 else { return ([], .invalidRegion, 0) }

    let ranked = usable.sorted { $0.fillRatio > $1.fillRatio }
    guard let best = ranked.first else { return ([], .invalidRegion, 0) }
    guard best.confidence >= 0.18 else {
      return ([], .uncertain, min(0.34, max(0.12, best.confidence)))
    }
    let second = ranked.dropFirst().first
    let secondSignal = second?.fillRatio ?? 0

    // Baseline/noise are estimated from every cell except the single strongest one,
    // so a genuine mark never pulls its own row's "blank" reference upward.
    let ascending = usable.map(\.fillRatio).sorted()
    let blankCount = max(1, ascending.count - 1)
    let baseline = median(Array(ascending.prefix(blankCount)))
    let blankMAD = median(Array(ascending.prefix(blankCount)).map { abs($0 - baseline) })
    let noise = max(0.012, blankMAD * 1.4826)

    let bestLift = best.fillRatio - baseline
    let secondLift = secondSignal - baseline
    let margin = best.fillRatio - secondSignal
    let ratio = secondSignal / max(best.fillRatio, 0.001)
    let populationSeparation = max(0.16, profile.filledCenter - profile.blankCenter)
    let decisionBoundary = min(0.72, max(0.34, profile.decisionBoundary))
    let weakBoundary = min(decisionBoundary - 0.035, max(0.18, profile.weakBoundary))
    let minimumMargin = min(0.22, max(0.060, profile.minimumSelectionMargin))
    let strongLift = max(0.13, max(populationSeparation * 0.20, noise * 3.2))
    let weakLift = max(0.085, max(populationSeparation * 0.13, noise * 2.3))

    // True double marks must contain two independently dark cells.  A runner-up
    // caused by a printed letter, JPEG ringing or monitor moire is not enough.
    if let second,
      best.confidence >= 0.28,
      second.confidence >= 0.28,
      best.fillRatio >= max(0.44, decisionBoundary * 0.90),
      second.fillRatio >= max(0.42, decisionBoundary * 0.86),
      bestLift >= max(0.19, max(populationSeparation * 0.27, noise * 3.6)),
      secondLift >= max(0.17, max(populationSeparation * 0.24, noise * 3.2)),
      ratio >= 0.80,
      margin <= max(0.15, minimumMargin * 1.25)
    {
      let selected = ranked.filter {
        $0.confidence >= 0.28
          && $0.fillRatio >= max(0.40, decisionBoundary * 0.82)
          && ($0.fillRatio - baseline) >= max(
            0.15, max(populationSeparation * 0.22, noise * 3.0))
          && $0.fillRatio / max(best.fillRatio, 0.001) >= 0.78
      }.map(\.choice)
      if selected.count >= 2 {
        return (selected, .multiple, min(0.97, 0.72 + min(bestLift, secondLift) * 0.25))
      }
    }

    // Strong absolute evidence.
    let absoluteStrong = best.fillRatio >= decisionBoundary
      && bestLift >= max(0.11, max(populationSeparation * 0.16, noise * 2.7))
      && margin >= minimumMargin * 0.72
    if absoluteStrong {
      return ([best.choice], .selected, selectedConfidence(best: best, lift: bestLift, margin: margin))
    }

    // Strong row-relative evidence.  This is the important phone-camera path: even
    // if every bubble becomes lighter/darker together, one clear spatial outlier wins.
    let relativeStrong = bestLift >= strongLift
      && margin >= max(minimumMargin * 0.72, noise * 2.15)
      && ratio <= 0.80
      && best.fillRatio >= max(0.30, weakBoundary)
      && best.confidence >= 0.28
    if relativeStrong {
      return ([best.choice], .selected, selectedConfidence(best: best, lift: bestLift, margin: margin))
    }

    // A slightly weaker but very isolated mark is still more plausible than an
    // invented Empty result.  It is returned for review rather than silently graded.
    let isolatedWeak = bestLift >= weakLift
      && margin >= max(minimumMargin * 0.48, noise * 1.65)
      && ratio <= 0.84
      && best.fillRatio >= max(0.18, weakBoundary * 0.78)
    if isolatedWeak {
      let confidence = min(0.78, max(0.50, 0.48 + bestLift * 0.55 + margin * 0.60))
      return ([best.choice], .weak, confidence)
    }

    // Truly blank rows have no standout cell; all five measurements stay close to
    // the same low printed-ink baseline.
    let blankBoundary = max(0.20, min(0.36, weakBoundary * 0.90))
    if best.fillRatio < blankBoundary && bestLift < max(0.085, noise * 2.0) {
      let confidence = min(0.96, max(0.62, 0.82 - best.fillRatio * 0.55 - bestLift * 0.55))
      return ([], .empty, confidence)
    }

    // Never fabricate a high-confidence answer from a tied row.
    let confidence = min(0.66, max(0.30, 0.36 + bestLift * 0.45 + margin * 0.50))
    // The measurements still expose the leading candidate in diagnostics, but an
    // unresolved row carries no selected choice and can never lower a student's
    // grade until a teacher confirms it.
    return ([], .uncertain, confidence)
  }

  private func selectedConfidence(best: BubbleMeasurement, lift: Double, margin: Double) -> Double {
    let absolute = min(1, best.fillRatio / 0.82)
    let liftScore = min(1, lift / 0.55)
    let marginScore = min(1, margin / 0.42)
    let quality = min(1, max(0, best.confidence))
    return min(0.999, 0.72 + absolute * 0.10 + liftScore * 0.08 + marginScore * 0.06 + quality * 0.04)
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
