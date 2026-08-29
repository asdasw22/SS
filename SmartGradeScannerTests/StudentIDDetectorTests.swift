import SwiftData
import XCTest

@testable import SmartGradeScanner

final class StudentIDDetectorTests: XCTestCase {
  func testDefinitionHasSevenColumnsAndTenRows() {
    let template = SampleDataSeeder.fixedOMRTemplate()
    XCTAssertEqual(template.studentID?.columns.count, 7)
    XCTAssertEqual(template.studentID?.digitRows.count, 10)
    XCTAssertEqual(template.studentID?.prefix, "320")
  }

  func testFixedTemplateSeparatesIDFromAnswers() {
    let template = SampleDataSeeder.fixedOMRTemplate()
    XCTAssertTrue(template.hasSafeSeparatedRegions)
    XCTAssertLessThan(template.pageAspectRatio, 1.0) // portrait 904x1280
    XCTAssertEqual(template.markers.count, 8)
    XCTAssertEqual(template.revision, 10)
    XCTAssertEqual(template.profileName, "FixedOMR-904x1280-Strict-v10")
    XCTAssertTrue(template.validationIssues.isEmpty)
  }

  // The legacy competing profiles (ReferenceSheet-591x520, ArabicGeneratedPortrait,
  // and the pre-v10 generated "Reference Answer Sheet" saved by the old exam
  // creator) were removed with the strict fixed-sheet redesign. Existing stores
  // are upgraded on launch instead of ever being scanned against the old geometry.
  @MainActor
  func testLegacyBundledTemplatesAreUpgradedToStrictProfileOnLaunch() throws {
    var legacy = SampleDataSeeder.fixedOMRTemplate()
    legacy.revision = 9
    legacy.profileName = "ReferenceSheet-591x520-v9"
    let container = try ModelContainer(
      for: Classroom.self, Student.self, Exam.self, AnswerKey.self, ExamTemplate.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    let context = ModelContext(container)
    let stored = ExamTemplate(name: "Reference Answer Sheet", definition: legacy)
    context.insert(stored)
    try context.save()

    SampleDataSeeder.seedIfNeeded(in: context)

    XCTAssertEqual(stored.name, "Fixed OMR Answer Sheet")
    XCTAssertEqual(stored.definition.profileName, "FixedOMR-904x1280-Strict-v10")
    XCTAssertEqual(stored.definition.revision, 10)
    XCTAssertTrue(stored.definition.isFixedOMRStrict)
  }

  func testFixedOMRTemplateIsStrictAndValid() {
    let template = SampleDataSeeder.fixedOMRTemplate()
    XCTAssertEqual(template.profileName, "FixedOMR-904x1280-Strict-v10")
    XCTAssertTrue(template.isFixedOMRStrict)
    XCTAssertEqual(template.pageAspectRatio, 904.0 / 1280.0, accuracy: 0.0001)
    XCTAssertEqual(template.questions.count, 20)
    XCTAssertTrue(template.questions.allSatisfy { $0.bubbles.count == 5 })
    XCTAssertEqual(template.studentID?.columns.count, 7)
    XCTAssertEqual(template.studentID?.digitRows.count, 10)
    XCTAssertEqual(template.studentID?.prefix, "320")
    XCTAssertEqual(template.markers.count, 8)
    XCTAssertTrue(template.validationIssues.isEmpty)
  }
}
