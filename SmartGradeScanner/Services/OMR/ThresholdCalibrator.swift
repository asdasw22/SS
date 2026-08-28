import Foundation

struct ThresholdCalibrator: Sendable {
  func calibratedProfile(
    samples: [Double],
    base: CalibrationProfile = CalibrationProfile(),
    expectedMarkedFraction: Double? = nil
  ) -> CalibrationProfile {
    let values = samples.filter { $0.isFinite }.map { min(1, max(0, $0)) }
    guard values.count >= 12 else { return base }

    let sorted = values.sorted()
    var lowCenter = percentile(sorted, 0.25)
    var highCenter = percentile(sorted, 0.92)
    guard highCenter - lowCenter >= 0.08 else { return base }

    var lowCluster: [Double] = []
    var highCluster: [Double] = []
    for _ in 0..<24 {
      lowCluster.removeAll(keepingCapacity: true)
      highCluster.removeAll(keepingCapacity: true)
      for value in values {
        if abs(value - lowCenter) <= abs(value - highCenter) {
          lowCluster.append(value)
        } else {
          highCluster.append(value)
        }
      }
      guard !lowCluster.isEmpty, !highCluster.isEmpty else { return base }
      let nextLow = robustMean(lowCluster)
      let nextHigh = robustMean(highCluster)
      let orderedLow = min(nextLow, nextHigh)
      let orderedHigh = max(nextLow, nextHigh)
      if abs(orderedLow - lowCenter) + abs(orderedHigh - highCenter) < 0.0004 {
        lowCenter = orderedLow
        highCenter = orderedHigh
        break
      }
      lowCenter = orderedLow
      highCenter = orderedHigh
    }

    let separation = highCenter - lowCenter
    let filledFraction = Double(highCluster.count) / Double(values.count)
    let plausibleFraction: Bool
    if let expectedMarkedFraction {
      let lower = max(0.015, expectedMarkedFraction * 0.20)
      let upper = min(0.60, expectedMarkedFraction * 2.8 + 0.08)
      plausibleFraction = filledFraction >= lower && filledFraction <= upper
    } else {
      plausibleFraction = filledFraction >= 0.02 && filledFraction <= 0.52
    }

    guard separation >= 0.12, plausibleFraction else { return base }

    var profile = base
    profile.blankCenter = lowCenter
    profile.filledCenter = highCenter
    profile.blankSpread = standardDeviation(lowCluster, mean: lowCenter)
    profile.filledSpread = standardDeviation(highCluster, mean: highCenter)

    // Keep a conservative gap above blank outlines/printed letters. The reader
    // should prefer "needs review" over inventing an answer.
    profile.weakBoundary = min(0.92, lowCenter + separation * 0.34)
    profile.decisionBoundary = min(0.96, lowCenter + separation * 0.58)
    profile.minimumSelectionMargin = min(0.27, max(0.09, separation * 0.20))
    return profile
  }

  private func robustMean(_ values: [Double]) -> Double {
    guard !values.isEmpty else { return 0 }
    let sorted = values.sorted()
    let trim = values.count >= 10 ? max(1, values.count / 10) : 0
    let slice = sorted.dropFirst(trim).dropLast(trim)
    let usable = slice.isEmpty ? sorted[...] : slice
    return usable.reduce(0, +) / Double(usable.count)
  }

  private func percentile(_ sorted: [Double], _ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let position = min(max(p, 0), 1) * Double(sorted.count - 1)
    let lower = Int(position.rounded(.down))
    let upper = Int(position.rounded(.up))
    if lower == upper { return sorted[lower] }
    let fraction = position - Double(lower)
    return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
  }

  private func standardDeviation(_ values: [Double], mean: Double) -> Double {
    guard values.count > 1 else { return 0 }
    let variance = values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count)
    return sqrt(max(0, variance))
  }
}
