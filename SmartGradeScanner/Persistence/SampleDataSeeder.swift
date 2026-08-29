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
      Student(
        studentID: "320234561204", name: "Ahmad Ali", grade: "Grade 8", section: "A",
        classroom: classroom),
      Student(
        studentID: "320234561205", name: "Omar Khaled", grade: "Grade 8", section: "A",
        classroom: classroom),
      Student(
        studentID: "320234561206", name: "Sara Hassan", grade: "Grade 8", section: "A",
        classroom: classroom),
      Student(
        studentID: "320234561207", name: "Lina Samir", grade: "Grade 8", section: "A",
        classroom: classroom),
    ].forEach { context.insert($0) }

    let exam = Exam(
      name: "Science Quiz", subject: "Science", classroom: classroom, numberOfQuestions: 20)
    let answerKey = AnswerKey(
      name: "Science Quiz Key",
      entries: Dictionary(
        uniqueKeysWithValues: (1...20).map { ($0, AnswerChoice.allCases[($0 - 1) % 5]) }))
    let template = ExamTemplate(
      name: "Science Answer Sheet", definition: SampleDataSeeder.template())
    exam.answerKey = answerKey
    exam.template = template
    context.insert(answerKey)
    context.insert(template)
    context.insert(exam)
    try? context.save()
  }

  @MainActor
  private static func upgradeBundledTemplateIfNeeded(in context: ModelContext) {
    let descriptor = FetchDescriptor<ExamTemplate>()
    guard let templates = try? context.fetch(descriptor) else { return }
    var changed = false
    for storedTemplate in templates {
      let definition = storedTemplate.definition
      let isBundled =
        storedTemplate.name == "Science Answer Sheet"
        || definition.isReferenceLandscapeSheet
        || definition.profileName == "ReferenceSheet-591x520"
      guard isBundled, definition.revision < 7 else { continue }

      let questionCount = min(max(definition.questions.count, 1), 20)
      let choiceCount = min(max(definition.questions.first?.bubbles.count ?? 5, 2), 5)
      storedTemplate.definition = template(
        questionCount: questionCount, choicesPerQuestion: choiceCount)
      changed = true
    }
    if changed { try? context.save() }
  }

  // Exact profile for the supplied 591 x 520 landscape answer sheet. Coordinates use
  // a top-left origin and are normalized to the detected paper, never the camera frame.
  static func template(questionCount: Int = 20, choicesPerQuestion: Int = 5) -> TemplateDefinition {
    let safeQuestionCount = min(max(questionCount, 1), 20)
    let safeChoiceCount = min(max(choicesPerQuestion, 2), 5)
    let choices = Array(AnswerChoice.allCases.prefix(safeChoiceCount))

    let bubbleWidth = 0.0203
    let bubbleHeight = 0.0232
    let leftXAll = [0.2919, 0.3164, 0.3418, 0.3672, 0.3917]
    let rightXAll = [0.4475, 0.4712, 0.4975, 0.5220, 0.5465]
    let leftX = Array(leftXAll.prefix(safeChoiceCount))
    let rightX = Array(rightXAll.prefix(safeChoiceCount))
    let rowY = [
      0.2104, 0.2471, 0.2857, 0.3243, 0.3610, 0.4015, 0.4392,
      0.5386, 0.5753, 0.6149, 0.6506, 0.6882, 0.7259, 0.7645,
      0.8031, 0.8417, 0.8803,
    ]

    var questions: [TemplateQuestionDefinition] = []
    for number in 1...safeQuestionCount {
      if number <= 17 {
        questions.append(
          question(
            number: number,
            xStarts: leftX,
            y: rowY[number - 1],
            width: bubbleWidth,
            height: bubbleHeight,
            choices: choices))
      } else {
        questions.append(
          question(
            number: number,
            xStarts: rightX,
            y: rowY[number - 18],
            width: bubbleWidth,
            height: bubbleHeight,
            choices: choices))
      }
    }

    let markers: [MarkerDefinition] = [
      marker(centerX: 0.2327, centerY: 0.1400, width: 0.0186, height: 0.0212),
      marker(centerX: 0.4873, centerY: 0.1873, width: 0.0135, height: 0.0154),
      marker(centerX: 0.7411, centerY: 0.1400, width: 0.0170, height: 0.0212),
      marker(centerX: 0.2327, centerY: 0.5415, width: 0.0186, height: 0.0212),
      marker(centerX: 0.4873, centerY: 0.5135, width: 0.0135, height: 0.0154),
      marker(centerX: 0.7411, centerY: 0.5415, width: 0.0170, height: 0.0212),
      marker(centerX: 0.2327, centerY: 0.9421, width: 0.0186, height: 0.0193),
      marker(centerX: 0.4873, centerY: 0.9469, width: 0.0135, height: 0.0135),
      marker(centerX: 0.7411, centerY: 0.9421, width: 0.0170, height: 0.0193),
    ]

    let columnsX = [0.4882, 0.5127, 0.5381, 0.5635, 0.5888, 0.6125, 0.6387, 0.6641, 0.6887]
    let rowsY = [0.5927, 0.6274, 0.6622, 0.6969, 0.7326, 0.7664, 0.8012, 0.8340, 0.8687, 0.9025]
    let columns = columnsX.map {
      NormalizedRect(x: $0, y: rowsY[0], width: bubbleWidth, height: bubbleHeight)
    }
    let rows = rowsY.map {
      NormalizedRect(x: columnsX[0], y: $0, width: bubbleWidth, height: bubbleHeight)
    }

    var calibration = CalibrationProfile()
    calibration.blankCenter = 0.44
    calibration.filledCenter = 0.95
    calibration.weakBoundary = 0.62
    calibration.decisionBoundary = 0.72
    calibration.minimumSelectionMargin = 0.15
    calibration.minimumMarkerCount = 4
    calibration.markerReprojectionTolerance = 0.032
    calibration.minimumLocalContrast = 0.045

    return TemplateDefinition(
      pageAspectRatio: 591.0 / 520.0,
      questions: questions,
      studentID: StudentIDDefinition(
        region: NormalizedRect(x: 0.475, y: 0.570, width: 0.245, height: 0.370),
        columns: columns,
        digitRows: rows,
        prefix: "320"
      ),
      markers: markers,
      ignoredAreas: [
        NormalizedRect(x: 0.00, y: 0.08, width: 0.23, height: 0.40),
        NormalizedRect(x: 0.00, y: 0.56, width: 0.23, height: 0.34),
        NormalizedRect(x: 0.50, y: 0.28, width: 0.23, height: 0.22),
        NormalizedRect(x: 0.75, y: 0.54, width: 0.25, height: 0.30),
      ],
      calibration: calibration,
      revision: 7,
      profileName: "ReferenceSheet-591x520-v7",
      strictRegistration: true,
      maximumAlignmentDrift: 0.110
    )
  }

  private static func question(
    number: Int,
    xStarts: [Double],
    y: Double,
    width: Double,
    height: Double,
    choices: [AnswerChoice]
  ) -> TemplateQuestionDefinition {
    TemplateQuestionDefinition(
      number: number,
      bubbles: zip(xStarts, choices).map { x, choice in
        BubbleCoordinate(
          choice: choice,
          rect: NormalizedRect(
            x: x,
            y: y,
            width: width,
            height: height))
      })
  }

  private static func marker(
    centerX: Double,
    centerY: Double,
    width: Double,
    height: Double
  ) -> MarkerDefinition {
    MarkerDefinition(
      kind: .registration,
      expectedRect: NormalizedRect(
        x: centerX - width / 2,
        y: centerY - height / 2,
        width: width,
        height: height))
  }
}
