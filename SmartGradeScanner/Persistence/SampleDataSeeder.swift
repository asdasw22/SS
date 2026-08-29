import CoreGraphics
import Foundation
import SwiftData

enum SampleDataSeeder {
  @MainActor
  static func seedIfNeeded(in context: ModelContext) {
    upgradeBundledTemplateIfNeeded(in: context)
    let descriptor = FetchDescriptor<Classroom>()
    guard (try? context.fetchCount(descriptor)) == 0 else { return }

    let classroom = Classroom(name: "Grade 8A", grade: "Grade 8", section: "A")
    context.insert(classroom)
    [
      Student(studentID: "320234561204", name: "Ahmad Ali", grade: "Grade 8", section: "A", classroom: classroom),
      Student(studentID: "320234561205", name: "Omar Khaled", grade: "Grade 8", section: "A", classroom: classroom),
      Student(studentID: "320234561206", name: "Sara Hassan", grade: "Grade 8", section: "A", classroom: classroom),
      Student(studentID: "320234561207", name: "Lina Samir", grade: "Grade 8", section: "A", classroom: classroom),
    ].forEach { context.insert($0) }

    let exam = Exam(name: "Science Quiz", subject: "Science", classroom: classroom, numberOfQuestions: 20)
    let demoKey: [Int: AnswerChoice] = [
      1: .c, 2: .a, 3: .d, 4: .b, 5: .e,
      6: .c, 7: .d, 8: .b, 9: .a, 10: .e,
      11: .c, 12: .b, 13: .d, 14: .a, 15: .c,
      16: .e, 17: .b, 18: .d, 19: .a, 20: .c,
    ]
    for question in exam.questions { question.correctAnswer = demoKey[question.number] }
    let answerKey = AnswerKey(name: "Science Quiz Key", entries: demoKey)
    let template = ExamTemplate(name: "Fixed OMR Answer Sheet", definition: SampleDataSeeder.fixedOMRTemplate())
    exam.answerKey = answerKey
    exam.template = template
    context.insert(answerKey)
    context.insert(template)
    context.insert(exam)
    try? context.save()
  }

  /// Any previously-seeded built-in template (old landscape "ReferenceSheet" or the
  /// approximate "ArabicGeneratedPortrait") is replaced with the single strict
  /// FixedOMR 904x1280 template on app launch.
  @MainActor
  private static func upgradeBundledTemplateIfNeeded(in context: ModelContext) {
    let descriptor = FetchDescriptor<ExamTemplate>()
    guard let templates = try? context.fetch(descriptor) else { return }
    var changed = false
    for storedTemplate in templates {
      let definition = storedTemplate.definition
      let isLegacyBundled =
        storedTemplate.name == "Science Answer Sheet"
        || storedTemplate.name == "Fixed OMR Answer Sheet"
        || definition.profileName?.hasPrefix("ReferenceSheet-") == true
        || definition.profileName?.hasPrefix("ArabicGeneratedPortrait-") == true
      guard isLegacyBundled, definition.revision < 10 else { continue }
      storedTemplate.name = "Fixed OMR Answer Sheet"
      storedTemplate.definition = fixedOMRTemplate()
      changed = true
    }
    if changed { try? context.save() }
  }

  /// The fixed OMR answer sheet this app is built around: 904x1280 portrait,
  /// exactly 20 questions with 5 bubbles each (A-E left to right), 8 registration
  /// squares, and a 7-column Student-ID grid read column by column. Every center
  /// below is derived straight from the reference layout by dividing x by 904 and
  /// y by 1280. Nothing here is estimated and nothing is read with OCR.
  static func fixedOMRTemplate() -> TemplateDefinition {
    let bubbleWidth = 30.0 / 904.0
    let bubbleHeight = 30.0 / 1280.0

    let topX = [276.0, 313.0, 350.0, 386.0, 423.0].map { $0 / 904.0 }
    let topY = [255.0, 297.0, 339.0, 384.0, 428.0, 472.0, 517.0].map { $0 / 1280.0 }
    let rightX = [536.0, 573.0, 610.0, 646.0, 683.0].map { $0 / 904.0 }
    let rightY = [255.0, 297.0, 339.0].map { $0 / 1280.0 }
    let bottomX = [267.0, 299.0, 332.0, 364.0, 397.0].map { $0 / 904.0 }
    let bottomY = [668.0, 715.0, 760.0, 807.0, 857.0, 903.0, 948.0, 997.0, 1042.0, 1091.0].map { $0 / 1280.0 }

    func question(number: Int, xCenters: [Double], yCenter: Double) -> TemplateQuestionDefinition {
      TemplateQuestionDefinition(
        number: number,
        bubbles: zip(xCenters, AnswerChoice.allCases).map { x, choice in
          BubbleCoordinate(
            choice: choice,
            rect: NormalizedRect(
              x: x - bubbleWidth / 2,
              y: yCenter - bubbleHeight / 2,
              width: bubbleWidth,
              height: bubbleHeight))
        })
    }

    var questions: [TemplateQuestionDefinition] = []
    for (offset, y) in topY.enumerated() {
      questions.append(question(number: offset + 1, xCenters: topX, yCenter: y))
    }
    for (offset, y) in bottomY.enumerated() {
      questions.append(question(number: 8 + offset, xCenters: bottomX, yCenter: y))
    }
    for (offset, y) in rightY.enumerated() {
      questions.append(question(number: 18 + offset, xCenters: rightX, yCenter: y))
    }
    questions.sort { $0.number < $1.number }

    let markerValues: [(Double, Double)] = [
      (57, 46), (850, 46), (184, 166), (184, 626), (878, 626),
      (57, 1212), (442, 1212), (795, 1212),
    ]
    let markerWidth = 26.0 / 904.0
    let markerHeight = 26.0 / 1280.0
    let markers = markerValues.map { cx, cy -> MarkerDefinition in
      MarkerDefinition(
        kind: .registration,
        expectedRect: NormalizedRect(
          x: cx / 904.0 - markerWidth / 2,
          y: cy / 1280.0 - markerHeight / 2,
          width: markerWidth,
          height: markerHeight))
    }

    let columnCentersX = [473.0, 509.0, 544.0, 579.0, 614.0, 649.0, 684.0].map { $0 / 904.0 }
    let digitRowsY = [706.0, 748.0, 790.0, 833.0, 876.0, 917.0, 960.0, 1002.0, 1044.0, 1085.0].map { $0 / 1280.0 }
    let columns = columnCentersX.map { centerX in
      NormalizedRect(
        x: centerX - bubbleWidth / 2,
        y: digitRowsY[0] - bubbleHeight / 2,
        width: bubbleWidth,
        height: bubbleHeight)
    }
    let rows = digitRowsY.map { centerY in
      NormalizedRect(
        x: columnCentersX[0] - bubbleWidth / 2,
        y: centerY - bubbleHeight / 2,
        width: bubbleWidth,
        height: bubbleHeight)
    }

    var calibration = CalibrationProfile()
    calibration.blankCenter = 0.12
    calibration.filledCenter = 0.84
    calibration.weakBoundary = 0.34
    calibration.decisionBoundary = 0.52
    calibration.minimumSelectionMargin = 0.12
    calibration.minimumMarkerCount = 6
    calibration.markerReprojectionTolerance = 0.030
    calibration.minimumLocalContrast = 0.040

    return TemplateDefinition(
      pageAspectRatio: 904.0 / 1280.0,
      questions: questions,
      studentID: StudentIDDefinition(
        region: NormalizedRect(x: 0.50, y: 0.53, width: 0.28, height: 0.34),
        columns: columns,
        digitRows: rows,
        prefix: "320"),
      markers: markers,
      ignoredAreas: [],
      calibration: calibration,
      revision: 10,
      profileName: "FixedOMR-904x1280-Strict-v10",
      strictRegistration: true,
      maximumAlignmentDrift: 0.100)
  }
}
