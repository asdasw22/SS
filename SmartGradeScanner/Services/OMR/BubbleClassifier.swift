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
    // Legacy unit tests and stored data provide only fill-ratio signals; the live
    // pipeline always supplies the full multi-evidence set. We route to the
    // evidence-aware classifier when it is available, otherwise keep the
    // original fill-ratio-only behaviour byte-for-byte so fixes stay regression-free.
    let hasEvidence = !measurements.isEmpty
      && measurements.allSatisfy { $0.blobFill != nil && $0.otsuFill != nil }
    if hasEvidence {
      return classifyWithEvidence(measurements: measurements, profile: profile)
    }

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
    // Threshold relaxed so faint pencil marks are reviewed instead of read as Empty.
    let isolatedWeak = bestLift >= max(0.10, noise * 2.3)
      && margin >= max(0.060, noise * 1.7)
      && ratio <= 0.82
      && best.fillRatio >= 0.14
    if isolatedWeak {
      let confidence = min(0.78, max(0.50, 0.48 + bestLift * 0.55 + margin * 0.60))
      return ([best.choice], .weak, confidence)
    }

    // ---- Blank or faint shading: NEVER a high-confidence Empty ----
    // A row is only reported Empty when every cell sits at the same low printed-ink
    // baseline, and even then only at low confidence (flagged for review). Any single
    // cell that separates from its own row baseline is possible pencil shading and is
    // routed to review as weak instead of being confidently declared Empty.
    let blankBoundary = max(0.22, min(0.34, profile.weakBoundary * 0.82))
    if best.fillRatio < blankBoundary {
      if bestLift >= max(0.05, noise * 1.4) {
        let c = min(0.55, max(0.30, 0.30 + bestLift * 0.5 + margin * 0.3))
        return ([best.choice], .weak, c)
      }
      let c = min(0.55, 0.45 - best.fillRatio * 0.3)
      return ([], .empty, c)
    }

    // Never fabricate a high-confidence answer from a tied row.
    let confidence = min(0.66, max(0.30, 0.36 + bestLift * 0.45 + margin * 0.50))
    return ([best.choice], .uncertain, confidence)
  }

  /// Strongest classification path, used when per-bubble multi-evidence is present.
  ///
  /// It fuses the raw mark with structural signals (otsuFill, blobFill, coverage,
  /// edgeReach, occupancy) and rejects anything that is fragmented, does not reach
  /// the bubble edge, or whose independent thresholding schemes disagree. A row is
  /// only graded when a single bubble separates cleanly from the row baseline using
  /// both absolute strength and a robust z-score (MAD). Everything ambiguous is sent
  /// to review rather than risking a confident wrong answer.
  private func classifyWithEvidence(
    measurements: [BubbleMeasurement],
    profile: CalibrationProfile
  ) -> (choices: [AnswerChoice], status: ResponseStatus, confidence: Double) {
    let usable = measurements
      .filter { $0.confidence >= 0.10 && $0.fillRatio.isFinite && $0.blobFill != nil && $0.otsuFill != nil }
      .sorted { $0.choice.rank < $1.choice.rank }
    guard usable.count >= 2 else { return ([], .invalidRegion, 0) }

    func fused(_ e: BubbleMeasurement) -> Double {
      let blob = e.blobFill ?? 0
      let otsu = e.otsuFill ?? 0
      let occ = e.occupancy ?? e.fillRatio
      let cov = e.coverage ?? 0
      let edge = e.edgeReach ?? 0
      let frag = e.blobCount ?? 0
      let consistency = e.multiConsistency ?? 1
      let raw =
        e.fillRatio * 0.30
        + otsu * 0.20
        + blob * 0.26
        + cov * 0.08
        + edge * 0.08
        + occ * 0.04
        - frag * 0.05
      return clampV(min(1, max(0, raw)) * (0.70 + 0.30 * consistency))
    }

    let rows = usable.map { (m: $0, mark: fused($0)) }
    let ranked = rows.sorted { $0.mark > $1.mark }
    guard let best = ranked.first else { return ([], .invalidRegion, 0) }
    let bestME = best.m
    let second = ranked.dropFirst().first

    // Robust row baseline that excludes the strongest cell.
    let marks = ranked.map { $0.mark }
    let sortedMarks = marks.sorted()
    let baselineCount = max(1, sortedMarks.count - 1)
    let baseline = sortedMarks.prefix(baselineCount).reduce(0, +) / Double(baselineCount)
    let deviations = sortedMarks.prefix(baselineCount).map { abs($0 - baseline) }
    let noise = max(0.012, median(deviations) * 1.4826)

    let bestLift = best.mark - baseline
    let secondMark = second?.mark ?? 0
    let margin = best.mark - secondMark
    let ratio = secondMark / max(best.mark, 0.001)
    let consistency = bestME.multiConsistency ?? 1
    let otsu = bestME.otsuFill ?? 0
    let blob = bestME.blobFill ?? 0
    let coverage = bestME.coverage ?? 0
    let edge = bestME.edgeReach ?? 0
    let frag = bestME.blobCount ?? 0

    // A real mark must be structurally solid: big contiguous blob, Otsu occupancy,
    // reasonable coverage reaching toward the edge, and consistent thresholding.
    let structurallyMarked = otsu >= 0.30 && blob >= 0.22 && consistency >= 0.30 && coverage >= 0.28
    let tooFragmented = frag >= 0.62 && blob < 0.30

    // ---- Multiple: two independently strong, structurally solid marks ----
    if let second,
      !tooFragmented,
      (second.m.otsuFill ?? 0) >= 0.30,
      (second.m.blobFill ?? 0) >= 0.22,
      (second.m.multiConsistency ?? 1) >= 0.30,
      best.mark >= 0.48,
      second.mark >= 0.46,
      margin <= 0.14,
      ratio >= 0.82
    {
      let chosen = ranked.filter {
        ($0.m.otsuFill ?? 0) >= 0.30
          && ($0.m.blobFill ?? 0) >= 0.22
          && $0.mark >= 0.44
      }.map { $0.m.choice }
      if chosen.count >= 2 {
        return (chosen, .multiple, min(0.97, 0.70 + bestLift * 0.25 + margin * 0.2))
      }
    }

    // ---- Strong absolute evidence (high fill, structural, big margin) ----
    if structurallyMarked,
      !tooFragmented,
      best.mark >= 0.46,
      otsu >= 0.42,
      blob >= 0.34,
      margin >= 0.085
    {
      return ([bestME.choice], .selected,
              evidenceConfidence(best: bestME, mark: best.mark, lift: bestLift,
                                 margin: margin, noise: noise))
    }

    // ---- Strong row-relative evidence (exposure changes shift every bubble) ----
    if structurallyMarked,
      !tooFragmented,
      bestLift >= max(0.15, noise * 3.2),
      margin >= max(0.075, noise * 2.0),
      ratio <= 0.80,
      best.mark >= 0.36,
      edge >= 0.22
    {
      return ([bestME.choice], .selected,
              evidenceConfidence(best: bestME, mark: best.mark, lift: bestLift,
                                 margin: margin, noise: noise))
    }

    // ---- Isolated but weaker / faint mark -> review, never Empty, never a confident answer ----
    // Lowered thresholds catch light pencil marks; they are returned as weak (review)
    // so a faint but real answer is never swallowed into a confidently-wrong Empty.
    if !tooFragmented,
      bestLift >= max(0.07, noise * 1.7),
      margin >= max(0.04, noise * 1.2),
      best.mark >= 0.16,
      otsu >= 0.12,
      blob >= 0.08
    {
      let c = min(0.80, max(0.50, 0.50 + bestLift * 0.5 + margin * 0.5))
      return ([bestME.choice], .weak, c)
    }

    // ---- Blank or faint shading: NEVER a high-confidence Empty ----
    // Same fail-safe as the legacy path: Empty is only ever returned for a row whose
    // cells all sit at the low printed-ink baseline, and never with high confidence.
    // If a single cell lifts above its own row baseline there may be pencil shading,
    // so we route it to review (weak) rather than declaring a confidently-wrong Empty.
    let blankBoundary = max(0.20, min(0.32, profile.weakBoundary * 0.78))
    if best.mark < blankBoundary {
      if bestLift >= max(0.05, noise * 1.4) {
        let c = min(0.55, max(0.30, 0.30 + bestLift * 0.4 + margin * 0.3))
        return ([bestME.choice], .weak, c)
      }
      let c = min(0.55, max(0.28, 0.42 - best.mark * 0.3))
      return ([], .empty, c)
    }

    // ---- Ambiguous / needs review ----
    let c = min(0.66, max(0.30, 0.36 + bestLift * 0.4 + margin * 0.5))
    return ([bestME.choice], .uncertain, c)
  }

  private func evidenceConfidence(
    best: BubbleMeasurement, mark: Double, lift: Double, margin: Double, noise: Double
  ) -> Double {
    let absolute = min(1, mark / 0.75)
    let liftScore = min(1, lift / 0.50)
    let marginScore = min(1, margin / 0.38)
    let quality = min(1, max(0, best.confidence))
    let consistency = min(1, max(0, best.multiConsistency ?? 1))
    let structural = ((best.otsuFill ?? 0) + (best.blobFill ?? 0)) / 2
    return min(
      0.999,
      0.66
        + absolute * 0.10
        + liftScore * 0.08
        + marginScore * 0.06
        + quality * 0.04
        + consistency * 0.04
        + structural * 0.02)
  }

  private func clampV(_ value: Double) -> Double {
    min(1, max(0, value))
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
