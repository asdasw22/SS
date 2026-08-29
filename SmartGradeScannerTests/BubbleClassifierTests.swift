import XCTest

@testable import SmartGradeScanner

final class BubbleClassifierTests: XCTestCase {
  private let profile = CalibrationProfile()

  private func measurements(_ values: [Double], confidence: Double = 1) -> [BubbleMeasurement] {
    zip(AnswerChoice.allCases, values).map {
      BubbleMeasurement(choice: $0.0, fillRatio: $0.1, darkness: $0.1, confidence: confidence)
    }
  }

  func testSelectedAnswer() {
    let output = BubbleClassifier().classify(
      measurements: measurements([0.08, 0.88, 0.10, 0.07, 0.09]), profile: profile)
    XCTAssertEqual(output.choices, [.b])
    XCTAssertEqual(output.status, .selected)
  }

  func testEmptyAnswer() {
    let output = BubbleClassifier().classify(
      measurements: measurements([0.08, 0.12, 0.10, 0.07, 0.09]), profile: profile)
    XCTAssertEqual(output.status, .empty)
    XCTAssertTrue(output.choices.isEmpty)
  }

  func testMultipleAnswers() {
    let output = BubbleClassifier().classify(
      measurements: measurements([0.08, 0.88, 0.10, 0.84, 0.09]), profile: profile)
    XCTAssertEqual(output.status, .multiple)
    XCTAssertEqual(Set(output.choices), Set([.b, .d]))
  }

  func testWeakMarkNeedsReview() {
    let output = BubbleClassifier().classify(
      measurements: measurements([0.08, 0.30, 0.10, 0.09, 0.08]), profile: profile)
    XCTAssertTrue(output.status == .weak || output.status == .uncertain)
    XCTAssertEqual(output.choices, [.b])
  }

  func testClearlyStrongestBubbleWinsEvenIfRunnerUpHasPrintedInk() {
    let output = BubbleClassifier().classify(
      measurements: measurements([0.88, 0.29, 0.11, 0.08, 0.10]), profile: profile)
    XCTAssertEqual(output.choices, [.a])
    XCTAssertEqual(output.status, .selected)
  }

  func testLowConfidenceIsNeverSelectedConfidently() {
    let output = BubbleClassifier().classify(
      measurements: measurements([0.08, 0.90, 0.10, 0.09, 0.08], confidence: 0.10),
      profile: profile)
    XCTAssertNotEqual(output.status, .selected)
    XCTAssertLessThan(output.confidence, 0.65)
  }

  func testPrintedGlyphNoiseDoesNotBecomeMultiple() {
    let output = BubbleClassifier().classify(
      measurements: measurements([0.14, 0.19, 0.82, 0.24, 0.17]), profile: profile)
    XCTAssertEqual(output.status, .selected)
    XCTAssertEqual(output.choices, [.c])
  }

  // MARK: - Multi-evidence path (live pipeline)

  private func evidenceRow(
    _ rows: [(AnswerChoice, Double, Double, Double)],
    coverage: Double = 0.6,
    edge: Double = 0.5,
    blobCount: Double = 0.25,
    confidence: Double = 1
  ) -> [BubbleMeasurement] {
    rows.map { choice, fill, otsu, blob in
      BubbleMeasurement(
        choice: choice, fillRatio: fill, darkness: fill, confidence: confidence,
        blobFill: blob, otsuFill: otsu, coverage: coverage, edgeReach: edge,
        occupancy: fill, blobCount: blobCount,
        multiConsistency: 1 - min(0.5, abs(otsu - blob) * 0.6))
    }
  }

  func testEvidencePathSelectsClearMark() {
    let row = evidenceRow([
      (.a, 0.08, 0.06, 0.05), (.b, 0.86, 0.88, 0.80),
      (.c, 0.10, 0.08, 0.06), (.d, 0.07, 0.05, 0.04), (.e, 0.09, 0.07, 0.06)
    ])
    let output = BubbleClassifier().classify(measurements: row, profile: profile)
    XCTAssertEqual(output.choices, [.b])
    XCTAssertEqual(output.status, .selected)
    XCTAssertGreaterThan(output.confidence, 0.7)
  }

  func testEvidencePathBlankRowIsEmpty() {
    let row = evidenceRow([
      (.a, 0.08, 0.06, 0.05), (.b, 0.12, 0.09, 0.06), (.c, 0.10, 0.07, 0.05),
      (.d, 0.07, 0.05, 0.04), (.e, 0.09, 0.06, 0.05)
    ])
    let output = BubbleClassifier().classify(measurements: row, profile: profile)
    XCTAssertEqual(output.status, .empty)
    XCTAssertTrue(output.choices.isEmpty)
  }

  func testEvidencePathRejectsFragmentedPrintedGlyphAsConfidentAnswer() {
    // Dark cell whose ink is thin/fragmented (a printed letter), not a solid blob.
    let row = evidenceRow([
      (.a, 0.80, 0.72, 0.16), (.b, 0.10, 0.08, 0.06), (.c, 0.09, 0.07, 0.05),
      (.d, 0.08, 0.06, 0.05), (.e, 0.11, 0.08, 0.06)
    ], blobCount: 0.72)
    let output = BubbleClassifier().classify(measurements: row, profile: profile)
    XCTAssertNotEqual(output.status, .selected)
    XCTAssertLessThan(output.confidence, 0.9)
  }

  func testEvidencePathDetectsTrueMultiple() {
    let row = evidenceRow([
      (.a, 0.85, 0.86, 0.78), (.b, 0.08, 0.06, 0.05), (.c, 0.83, 0.84, 0.76),
      (.d, 0.09, 0.07, 0.06), (.e, 0.10, 0.08, 0.06)
    ])
    let output = BubbleClassifier().classify(measurements: row, profile: profile)
    XCTAssertEqual(output.status, .multiple)
    XCTAssertEqual(Set(output.choices), Set([.a, .c]))
  }

  func testEvidencePathWeakMarkNeedsReview() {
    let row = evidenceRow([
      (.a, 0.08, 0.06, 0.05), (.b, 0.34, 0.30, 0.20), (.c, 0.10, 0.08, 0.06),
      (.d, 0.09, 0.07, 0.05), (.e, 0.08, 0.06, 0.05)
    ])
    let output = BubbleClassifier().classify(measurements: row, profile: profile)
    XCTAssertTrue(output.status == .weak || output.status == .uncertain)
  }
}
