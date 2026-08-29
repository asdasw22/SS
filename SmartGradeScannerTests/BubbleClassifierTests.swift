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

  func testUncertainTieDoesNotInventAChoice() {
    let output = BubbleClassifier().classify(
      measurements: measurements([0.36, 0.40, 0.37, 0.39, 0.35]), profile: profile)
    XCTAssertEqual(output.status, .uncertain)
    XCTAssertTrue(output.choices.isEmpty)
  }

  func testCaptureCalibrationCanConfirmAConsistentFaintMark() {
    var calibrated = profile
    calibrated.blankCenter = 0.13
    calibrated.filledCenter = 0.56
    calibrated.weakBoundary = 0.25
    calibrated.decisionBoundary = 0.38
    calibrated.minimumSelectionMargin = 0.08
    let output = BubbleClassifier().classify(
      measurements: measurements([0.13, 0.45, 0.14, 0.12, 0.15]), profile: calibrated)
    XCTAssertEqual(output.status, .selected)
    XCTAssertEqual(output.choices, [.b])
  }
}
