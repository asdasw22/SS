import CoreGraphics
import XCTest

@testable import SmartGradeScanner

final class OMRProcessorTests: XCTestCase {
  func testNormalizedCoordinatesRemainStableAcrossImageSizes() {
    let coordinate = NormalizedRect(x: 0.25, y: 0.4, width: 0.1, height: 0.08)
    let small = coordinate.rect(in: CGSize(width: 1000, height: 1400))
    let large = coordinate.rect(in: CGSize(width: 2000, height: 2800))
    XCTAssertEqual(small.midX / 1000, large.midX / 2000, accuracy: 0.0001)
    XCTAssertEqual(small.midY / 1400, large.midY / 2800, accuracy: 0.0001)
  }

  func testPerspectiveReprojectionErrorIsMeasured() {
    let source = [
      CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1),
    ]
    let distorted = [
      CGPoint(x: 0.02, y: 0.01), CGPoint(x: 0.99, y: 0.04), CGPoint(x: 0.96, y: 0.98),
      CGPoint(x: 0.01, y: 0.95),
    ]
    XCTAssertLessThan(
      HomographySolver().reprojectionError(source: source, destination: distorted), 0.06)
  }

  func testHomographyRecoversPerspectiveWarp() {
    let source = [
      CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
      CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1),
    ]
    let destination = [
      CGPoint(x: 0.12, y: 0.31), CGPoint(x: 0.88, y: 0.28),
      CGPoint(x: 0.82, y: 0.83), CGPoint(x: 0.16, y: 0.85),
    ]
    guard let transform = HomographySolver().solve(source: source, destination: destination) else {
      return XCTFail("Expected a valid projective transform")
    }
    XCTAssertLessThan(
      HomographySolver().reprojectionError(
        transform: transform, source: source, destination: destination),
      0.001)
  }

  func testLowConfidenceClassificationNeverSelectsConfidently() {
    let values = AnswerChoice.allCases.map {
      BubbleMeasurement(choice: $0, fillRatio: 0.82, darkness: 0.82, confidence: 0.1)
    }
    let output = BubbleClassifier().classify(measurements: values, profile: CalibrationProfile())
    XCTAssertNotEqual(output.status, .selected)
    XCTAssertLessThan(output.confidence, 0.65)
  }

  func testAffineAlignmentRecoversSmallCameraShift() {
    let expected: [CGPoint] = [
      CGPoint(x: 0.2, y: 0.15), CGPoint(x: 0.75, y: 0.15),
      CGPoint(x: 0.2, y: 0.55), CGPoint(x: 0.75, y: 0.55),
      CGPoint(x: 0.2, y: 0.92), CGPoint(x: 0.75, y: 0.92),
    ]
    let markers = expected.map { point in
      DetectedMarker(
        expectedCenter: point,
        center: CGPoint(x: point.x * 0.985 + 0.012, y: point.y * 1.01 - 0.006),
        confidence: 0.95,
        kind: .registration)
    }
    var template = SampleDataSeeder.template()
    template.markers = expected.map {
      MarkerDefinition(
        kind: .registration,
        expectedRect: NormalizedRect(
          x: Double($0.x) - 0.01,
          y: Double($0.y) - 0.01,
          width: 0.02,
          height: 0.02))
    }
    template.calibration.minimumMarkerCount = 5
    let report = TemplateAlignmentService().validate(markers: markers, template: template)
    XCTAssertTrue(report.isCompatible)
    XCTAssertLessThan(report.reprojectionError, 0.01)
  }
  func testABCDReferenceTemplateNeverScansEColumn() {
    let template = SampleDataSeeder.template(questionCount: 20, choicesPerQuestion: 4)
    XCTAssertEqual(template.questions.count, 20)
    XCTAssertTrue(template.questions.allSatisfy { $0.bubbles.map(\.choice) == [.a, .b, .c, .d] })
    XCTAssertFalse(template.questions.flatMap(\.bubbles).contains { $0.choice == .e })
    XCTAssertTrue(template.hasSafeSeparatedRegions)
  }

  func testReferenceTemplateKeepsStudentIDOutsideQuestionZones() {
    let template = SampleDataSeeder.template()
    guard let id = template.studentID else {
      return XCTFail("Missing Student ID definition")
    }
    for bubble in template.questions.flatMap(\.bubbles) {
      XCTAssertLessThan(bubble.rect.intersectionRatio(with: id.region), 0.02)
    }
  }

  func testAlignmentRejectsLargeShiftTowardStudentIDGrid() {
    var template = SampleDataSeeder.template()
    template.calibration.minimumMarkerCount = 5
    let markers = template.markers.map { marker in
      let expected = marker.expectedRect.center
      return DetectedMarker(
        expectedCenter: expected,
        center: CGPoint(x: expected.x + 0.18, y: expected.y),
        confidence: 0.98,
        kind: .registration)
    }
    let report = TemplateAlignmentService().validate(markers: markers, template: template)
    XCTAssertFalse(report.isCompatible)
    XCTAssertFalse(report.geometryIsSane)
  }

}
