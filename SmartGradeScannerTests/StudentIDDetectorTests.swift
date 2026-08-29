import XCTest

@testable import SmartGradeScanner

final class StudentIDDetectorTests: XCTestCase {
  func testDefinitionHasNineColumnsAndTenRows() {
    let template = SampleDataSeeder.template()
    XCTAssertEqual(template.studentID?.columns.count, 9)
    XCTAssertEqual(template.studentID?.digitRows.count, 10)
    XCTAssertEqual(template.studentID?.prefix, "320")
  }

  func testReferenceTemplateSeparatesIDFromAnswers() {
    let template = SampleDataSeeder.template()
    XCTAssertTrue(template.hasSafeSeparatedRegions)
    XCTAssertGreaterThan(template.pageAspectRatio, 1.0)
    XCTAssertEqual(template.markers.count, 9)
    XCTAssertEqual(template.revision, 11)
    XCTAssertEqual(template.profileName, "ReferenceSheet-591x520-v11")
    XCTAssertTrue(template.validationIssues.isEmpty)
  }

  func testArabicPortraitProfileHasSeparatePhysicalIDGrid() {
    let template = SampleDataSeeder.arabicPortraitTemplate()
    XCTAssertLessThan(template.pageAspectRatio, 1.0)
    XCTAssertEqual(template.questions.count, 20)
    XCTAssertEqual(template.studentID?.columns.count, 7)
    XCTAssertEqual(template.studentID?.digitRows.count, 10)
    XCTAssertEqual(template.profileName, "ArabicGeneratedPortrait-v11")
    XCTAssertTrue(template.validationIssues.isEmpty)
  }

  func testBundledUpgradePreservesPortraitGeometry() {
    var legacy = SampleDataSeeder.arabicPortraitTemplate()
    legacy.revision = 9
    legacy.profileName = "ArabicGeneratedPortrait-v9"

    let upgraded = SampleDataSeeder.upgradedBundledDefinition(from: legacy)

    XCTAssertEqual(upgraded.revision, 11)
    XCTAssertEqual(upgraded.profileName, "ArabicGeneratedPortrait-v11")
    XCTAssertLessThan(upgraded.pageAspectRatio, 1)
    XCTAssertEqual(upgraded.studentID?.columns.count, 7)
  }
}
