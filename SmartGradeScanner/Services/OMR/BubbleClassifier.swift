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
      .filter { $0.confidence >= 0.10 && $0.fillRatio.isFinite }
      .sorted { $0.choice.rank < $1.choice.rank }
    guard usable.count >= 2 else { return ([], .invalidRegion, 0) }

    let ranked = usable.sorted { $0.fillRatio > $1.fillRatio }
    guard let best = ranked.first else { return ([], .invalidRegion, 0) }
    guard best.confidence >= 0.18 else {
      return ([best.choice], .uncertain, min(0.34, max(0.12, best.confidence)))
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

    // True double marks must contain two independently dark cells.  A runner-up
    // caused by a printed letter, JPEG ringing or monitor moire is not enough.
    if let second,
      best.fillRatio >= 0.52,
      second.fillRatio >= 0.50,
      bestLift >= max(0.24, noise * 4.0),
      secondLift >= max(0.22, noise * 3.6),
      ratio >= 0.86,
      margin <= 0.14
    {
      let selected = ranked.filter {
        $0.fillRatio >= 0.48
          && ($0.fillRatio - baseline) >= max(0.20, noise * 3.3)
          && $0.fillRatio / max(best.fillRatio, 0.001) >= 0.84
      }.map(\.choice)
      if selected.count >= 2 {
        return (selected, .multiple, min(0.97, 0.72 + min(bestLift, secondLift) * 0.25))
      }
    }

    // Strong absolute evidence.
    if best.fillRatio >= 0.50 && margin >= 0.10 {
      return ([best.choice], .selected, selectedConfidence(best: best, lift: bestLift, margin: margin))
    }

    // Strong row-relative evidence.  This is the important phone-camera path: even
    // if every bubble becomes lighter/darker together, one clear spatial outlier wins.
    let relativeStrong = bestLift >= max(0.15, noise * 3.2)
      && margin >= max(0.085, noise * 2.2)
      && ratio <= 0.78
      && best.fillRatio >= 0.36
    if relativeStrong {
      return ([best.choice], .selected, selectedConfidence(best: best, lift: bestLift, margin: margin))
    }

    // A slightly weaker but very isolated mark is still more plausible than an
    // invented Empty result.  It is returned for review rather than silently graded.
    let isolatedWeak = bestLift >= max(0.10, noise * 2.3)
      && margin >= max(0.060, noise * 1.7)
      && ratio <= 0.82
      && best.fillRatio >= 0.20
    if isolatedWeak {
      let confidence = min(0.78, max(0.50, 0.48 + bestLift * 0.55 + margin * 0.60))
      return ([best.choice], .weak, confidence)
    }

    // Truly blank rows have no standout cell; all five measurements stay close to
    // the same low printed-ink baseline.
    let blankBoundary = max(0.22, min(0.34, profile.weakBoundary * 0.82))
    if best.fillRatio < blankBoundary && bestLift < max(0.085, noise * 2.0) {
      let confidence = min(0.96, max(0.62, 0.82 - best.fillRatio * 0.55 - bestLift * 0.55))
      return ([], .empty, confidence)
    }

    // Never fabricate a high-confidence answer from a tied row.
    let confidence = min(0.66, max(0.30, 0.36 + bestLift * 0.45 + margin * 0.50))
    return ([best.choice], .uncertain, confidence)
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
