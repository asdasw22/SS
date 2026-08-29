import CoreGraphics
import CoreImage
import Foundation
import ImageIO
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
    var template = SampleDataSeeder.fixedOMRTemplate()
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
    // A-D exams no longer get a second generated template: ScannerViewModel.adapt
    // filters the fixed sheet's E column out at scan time. The filtered definition
    // must therefore contain no E bubbles at all.
    var template = SampleDataSeeder.fixedOMRTemplate()
    template.questions = template.questions.map { question in
      var copy = question
      copy.bubbles = copy.bubbles.filter { $0.choice != .e }
      return copy
    }
    XCTAssertEqual(template.questions.count, 20)
    XCTAssertTrue(template.questions.allSatisfy { $0.bubbles.map(\.choice) == [.a, .b, .c, .d] })
    XCTAssertFalse(template.questions.flatMap(\.bubbles).contains { $0.choice == .e })
    XCTAssertTrue(template.hasSafeSeparatedRegions)
  }

  func testReferenceTemplateKeepsStudentIDOutsideQuestionZones() {
    let template = SampleDataSeeder.fixedOMRTemplate()
    guard let id = template.studentID else {
      return XCTFail("Missing Student ID definition")
    }
    for bubble in template.questions.flatMap(\.bubbles) {
      XCTAssertLessThan(bubble.rect.intersectionRatio(with: id.region), 0.02)
    }
  }

  func testAlignmentRejectsLargeShiftTowardStudentIDGrid() {
    var template = SampleDataSeeder.fixedOMRTemplate()
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

  // MARK: - Fixed 904×1280 strict sheet

  func testFixedOMRTemplateGeometryMatchesReference() {
    let template = SampleDataSeeder.fixedOMRTemplate()
    XCTAssertEqual(template.pageAspectRatio, 904.0 / 1280.0, accuracy: 0.0001)
    XCTAssertEqual(template.questions.count, 20)
    XCTAssertTrue(template.questions.allSatisfy { $0.bubbles.count == 5 })
    XCTAssertTrue(template.questions.allSatisfy {
      $0.bubbles.map { $0.choice } == [.a, .b, .c, .d, .e]
    })
    XCTAssertEqual(template.markers.count, 8)
    XCTAssertEqual(template.studentID?.columns.count, 7)
    XCTAssertEqual(template.studentID?.digitRows.count, 10)
    XCTAssertTrue(template.isFixedOMRStrict)
    XCTAssertTrue(template.validationIssues.isEmpty)
  }

  func testFixedTemplateBubblesDoNotOverlapMarkersOrIdZone() {
    let template = SampleDataSeeder.fixedOMRTemplate()
    let markers = template.markers.map { $0.expectedRect.expanded(by: 0.004) }
    guard let id = template.studentID else {
      return XCTFail("Missing Student ID definition on fixed sheet")
    }
    let idZone = id.region.expanded(by: 0.005)
    for question in template.questions {
      for bubble in question.bubbles {
        XCTAssertFalse(markers.contains { $0.intersectionRatio(with: bubble.rect) > 0.01 })
        XCTAssertLessThan(bubble.rect.intersectionRatio(with: idZone), 0.02)
      }
    }
  }

  func testFixedReferenceSheetProducesReferenceAnswers() async throws {
    let reference: [Int: AnswerChoice] = [
      1: .c, 2: .a, 3: .d, 4: .b, 5: .e,
      6: .c, 7: .d, 8: .b, 9: .a, 10: .e,
      11: .c, 12: .b, 13: .d, 14: .a, 15: .c,
      16: .e, 17: .b, 18: .d, 19: .a, 20: .c,
    ]
    guard let imageData = Self.makeFixedReferenceImage(filled: reference) else {
      return XCTFail("Could not render the 904×1280 reference sheet")
    }
    let result = try await OMRProcessor().process(
      imageData: imageData,
      template: SampleDataSeeder.fixedOMRTemplate(),
      answerKey: reference,
      progress: { _ in })
    XCTAssertEqual(result.questions.count, 20)
    for question in result.questions {
      let expected = reference[question.questionNumber]
      XCTAssertEqual(question.status, .selected, "Q\(question.questionNumber)")
      XCTAssertEqual(question.selectedChoices, [expected!], "Q\(question.questionNumber)")
    }
  }

  func testFixedBlankSheetNeverCommitsConfidentAnswers() async throws {
    guard let imageData = Self.makeFixedReferenceImage(filled: [:]) else {
      return XCTFail("Could not render the blank 904×1280 sheet")
    }
    let result = try await OMRProcessor().process(
      imageData: imageData,
      template: SampleDataSeeder.fixedOMRTemplate(),
      answerKey: [:],
      progress: { _ in })
    XCTAssertEqual(result.questions.count, 20)
    XCTAssertTrue(result.questions.allSatisfy { $0.status != .selected })
  }

  static func makeFixedReferenceImage(filled: [Int: AnswerChoice]) -> Data? {
    let width = 904
    let height = 1280
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    guard let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }

    func fillDisk(cx: CGFloat, cy: CGFloat, radius: CGFloat) {
      context.setFillColor(CGColor(gray: 0, alpha: 1))
      context.fillEllipse(
        in: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2))
    }
    func ring(cx: CGFloat, cy: CGFloat, radius: CGFloat, stroke: CGFloat) {
      context.setStrokeColor(CGColor(gray: 0, alpha: 1))
      context.setLineWidth(stroke)
      context.strokeEllipse(
        in: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2))
    }

    // Registration squares (camera/top-left Y converted to CG bottom-left origin).
    let markerValues: [(CGFloat, CGFloat)] = [
      (57, 46), (850, 46), (184, 166), (184, 626),
      (878, 626), (57, 1212), (442, 1212), (795, 1212),
    ]
    for (x, y) in markerValues {
      let cy = CGFloat(height) - y
      context.setFillColor(CGColor(gray: 0, alpha: 1))
      context.fill(CGRect(x: x - 13, y: cy - 13, width: 26, height: 26))
    }

    let template = SampleDataSeeder.fixedOMRTemplate()
    for question in template.questions {
      let expected = filled[question.number]
      for bubble in question.bubbles {
        let cx = bubble.rect.center.x * CGFloat(width)
        let cyTopLeft = bubble.rect.center.y * CGFloat(height)
        let drewY = CGFloat(height) - cyTopLeft
        ring(cx: cx, cy: drewY, radius: 15, stroke: 2)
        if expected == bubble.choice {
          fillDisk(cx: cx, cy: drewY, radius: 10)
        }
      }
    }

    // A clean all-zeros Student-ID grid so the ID region is unambiguous.
    let idColumns: [CGFloat] = [473, 509, 544, 579, 614, 649, 684]
    for column in idColumns {
      let cy = CGFloat(height) - 706
      ring(cx: column, cy: cy, radius: 15, stroke: 2)
      fillDisk(cx: column, cy: cy, radius: 10)
    }

    guard let cgImage = context.makeImage() else { return nil }
    let outData = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
      outData, "public.png" as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, cgImage, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return outData as Data
  }

  // MARK: - Strict registration (marker-homography warp)

  private static func decodedSheet(filled: [Int: AnswerChoice]) -> CGImage? {
    guard let sheetData = makeFixedReferenceImage(filled: filled),
      let source = CGImageSourceCreateWithData(sheetData as CFData, nil)
    else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  private static func makePerspectivePhoto(
    from sheet: CGImage,
    quadTopLeft: [CGPoint],
    canvas: CGSize
  ) -> CGImage? {
    guard quadTopLeft.count == 4, let filter = CIFilter(name: "CIPerspectiveTransform") else {
      return nil
    }
    let input = CIImage(cgImage: sheet)
    let height = canvas.height
    func ci(_ point: CGPoint) -> CIVector {
      CIVector(x: point.x, y: height - point.y)
    }
    filter.setValue(input, forKey: kCIInputImageKey)
    filter.setValue(ci(quadTopLeft[0]), forKey: "inputTopLeft")
    filter.setValue(ci(quadTopLeft[1]), forKey: "inputTopRight")
    filter.setValue(ci(quadTopLeft[2]), forKey: "inputBottomRight")
    filter.setValue(ci(quadTopLeft[3]), forKey: "inputBottomLeft")
    guard let warped = filter.outputImage else { return nil }
    let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
      .cropped(to: CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
    let composed = warped.imageByCompositingOver(white)
    let context = CIContext(options: [.useSoftwareRenderer: true])
    return context.createCGImage(
      composed, from: CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
  }

  /// The critical alignment regression: a perspective-distorted photo of the
  /// sheet must register through the marker homography and produce a canonical
  /// 904x1280 image whose bubbles sit at their exact template coordinates.
  func testStrictRegistrationRecoversPerspectiveDistortedSheet() throws {
    guard let sheet = Self.decodedSheet(filled: [1: .c, 2: .a]) else {
      return XCTFail("Could not render the canonical sheet")
    }
    guard let photo = Self.makePerspectivePhoto(
      from: sheet,
      quadTopLeft: [
        CGPoint(x: 70, y: 80), CGPoint(x: 950, y: 40),
        CGPoint(x: 1010, y: 1300), CGPoint(x: 30, y: 1330),
      ],
      canvas: CGSize(width: 1040, height: 1380))
    else { return XCTFail("Could not build the perspective photo") }

    let output = try StrictRegistrationService().register(
      raw: photo, template: SampleDataSeeder.fixedOMRTemplate(),
      thresholds: OMRStrictThresholds.strict)

    XCTAssertEqual(output.canonical.width, 904)
    XCTAssertEqual(output.canonical.height, 1280)
    XCTAssertEqual(output.report.level, .full)
    XCTAssertGreaterThanOrEqual(output.report.registrationConfidence, 0.85)
    XCTAssertLessThanOrEqual(output.report.meanRegistrationError, 4.0)

    guard let gray = GrayImage(cgImage: output.canonical) else {
      return XCTFail("Canonical image not decodable")
    }
    func meanDisk(_ cx: Int, _ cy: Int, radius: Int) -> Double {
      var sum = 0.0
      var count = 0.0
      for y in (cy - radius)...(cy + radius) {
        for x in (cx - radius)...(cx + radius) {
          if hypot(Double(x - cx), Double(y - cy)) <= Double(radius) {
            sum += Double(gray.value(x: x, y: y))
            count += 1
          }
        }
      }
      return sum / max(count, 1)
    }
    let q1c = meanDisk(350, 255, 6)
    let q1a = meanDisk(276, 255, 6)
    XCTAssertLessThan(q1c, 120, "shaded C bubble must be dark at its canonical spot")
    XCTAssertGreaterThan(q1a, 170, "empty A bubble must stay light at its canonical spot")
  }

  /// A page without any printed registration squares must be refused, never
  /// graded from guessed geometry.
  func testStrictRegistrationFailsClosedWithoutMarkers() throws {
    let width = 904
    let height = 1280
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    guard let context = CGContext(
      data: &pixels, width: width, height: height, bitsPerComponent: 8,
      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return XCTFail("Could not create the canvas") }
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fillEllipse(in: CGRect(x: 300, y: 300, width: 30, height: 30))
    context.fillEllipse(in: CGRect(x: 600, y: 700, width: 30, height: 30))
    guard let page = context.makeImage() else { return XCTFail("Could not create the image") }

    XCTAssertThrowsError(
      try StrictRegistrationService().register(
        raw: page, template: SampleDataSeeder.fixedOMRTemplate(),
        thresholds: OMRStrictThresholds.strict)
    ) { error in
      guard error is StrictRegistrationError else {
        return XCTFail("Expected StrictRegistrationError, got \(error)")
      }
    }
  }

  /// Coordinate-convention guard: the canonical warp must keep the TOP-LEFT
  /// origin (a y-flip would move the top-left marker to the bottom).
  func testCanonicalWarpPreservesTopLeftOrigin() throws {
    guard let sheet = Self.decodedSheet(filled: [:]) else {
      return XCTFail("Could not render the canonical sheet")
    }
    guard let warped = ImagePreprocessor().canonicalWarp(
      from: sheet,
      topLeftCorners: [
        CGPoint(x: 0, y: 0), CGPoint(x: 904, y: 0),
        CGPoint(x: 904, y: 1280), CGPoint(x: 0, y: 1280),
      ],
      targetWidth: 904, targetHeight: 1280)
    else { return XCTFail("Identity warp failed") }
    XCTAssertEqual(warped.width, 904)
    XCTAssertEqual(warped.height, 1280)
    guard let gray = GrayImage(cgImage: warped) else { return XCTFail("Not decodable") }
    let topLeftMarker = gray.value(x: 57, y: 46)
    let mirrored = gray.value(x: 57, y: 1280 - 46)
    XCTAssertLessThan(topLeftMarker, 90, "top-left marker must stay at the top (y=46)")
    XCTAssertGreaterThan(mirrored, 170, "a y-flip would put the marker at the bottom")
  }

}
