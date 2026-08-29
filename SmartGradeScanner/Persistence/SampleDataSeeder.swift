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
    // The bundled demo key matches TestAssets/SmartGradeScanner-v8-Arabic-Valid-Filled.png
    // exactly, so a fresh install has a deterministic end-to-end grading test.
    let demoKey: [Int: AnswerChoice] = [
      1: .c, 2: .a, 3: .d, 4: .b, 5: .e,
      6: .c, 7: .d, 8: .b, 9: .a, 10: .e,
      11: .c, 12: .b, 13: .d, 14: .a, 15: .c,
      16: .e, 17: .b, 18: .d, 19: .a, 20: .c,
    ]
    for question in exam.questions { question.correctAnswer = demoKey[question.number] }
    let answerKey = AnswerKey(name: "Science Quiz Key", entries: demoKey)
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
      guard isBundled, definition.revision < 8 else { continue }

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
    calibration.blankCenter = 0.12
    calibration.filledCenter = 0.84
    calibration.weakBoundary = 0.34
    calibration.decisionBoundary = 0.52
    calibration.minimumSelectionMargin = 0.12
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
      revision: 8,
      profileName: "ReferenceSheet-591x520-v8",
      strictRegistration: true,
      maximumAlignmentDrift: 0.110
    )
  }

  // Exact profile for the portrait Arabic demo sheet that was used during camera
  // testing. This is intentionally a separate profile from the 591x520 university
  // sheet: forcing a portrait sheet through the landscape coordinates is what caused
  // the earlier plausible-looking but incorrect Multiple/Empty answers.
  static func arabicPortraitTemplate(
    questionCount: Int = 20,
    choicesPerQuestion: Int = 5
  ) -> TemplateDefinition {
    let safeQuestionCount = min(max(questionCount, 1), 20)
    let safeChoiceCount = min(max(choicesPerQuestion, 2), 5)
    let choices = Array(AnswerChoice.allCases.prefix(safeChoiceCount))

    let topCentersX = [0.3060, 0.3468, 0.3876, 0.4279, 0.4682]
    let topRightCentersX = [0.5935, 0.6345, 0.6750, 0.7156, 0.7562]
    let bottomCentersX = [0.2955, 0.3316, 0.3676, 0.4032, 0.4393]
    let topRows = [0.1994, 0.2322, 0.2656, 0.3003, 0.3348, 0.3693, 0.4038]
    let bottomRows = [0.5221, 0.5590, 0.5955, 0.6324, 0.6692, 0.7060, 0.7426, 0.7790, 0.8157, 0.8522]
    let topBubbleSize = CGSize(width: 0.0320, height: 0.0232)
    let bottomBubbleSize = CGSize(width: 0.0295, height: 0.0236)

    func makeQuestion(number: Int, centersX: [Double], centerY: Double, size: CGSize)
      -> TemplateQuestionDefinition
    {
      TemplateQuestionDefinition(
        number: number,
        bubbles: zip(centersX.prefix(safeChoiceCount), choices).map { centerX, choice in
          BubbleCoordinate(
            choice: choice,
            rect: NormalizedRect(
              x: centerX - Double(size.width) / 2,
              y: centerY - Double(size.height) / 2,
              width: Double(size.width),
              height: Double(size.height)))
        })
    }

    var questions: [TemplateQuestionDefinition] = []
    for number in 1...safeQuestionCount {
      if number <= 7 {
        questions.append(
          makeQuestion(
            number: number,
            centersX: topCentersX,
            centerY: topRows[number - 1],
            size: topBubbleSize))
      } else if number <= 17 {
        questions.append(
          makeQuestion(
            number: number,
            centersX: bottomCentersX,
            centerY: bottomRows[number - 8],
            size: bottomBubbleSize))
      } else {
        questions.append(
          makeQuestion(
            number: number,
            centersX: topRightCentersX,
            centerY: topRows[number - 18],
            size: topBubbleSize))
      }
    }

    // The AI-generated demo sheet unfortunately contains seven ID columns rather
    // than the nine requested by the printed 12-digit example. We model the seven
    // physical columns honestly; OMRProcessor can use OCR of the printed numeric ID
    // as a fallback when the grid is incomplete or multiply marked.
    let idCentersX = [0.5247, 0.5640, 0.6029, 0.6418, 0.6803, 0.7187, 0.7571]
    let idRowsY = [0.5519, 0.5848, 0.6176, 0.6511, 0.6840, 0.7168, 0.7497, 0.7825, 0.8153, 0.8479]
    let idWidth = 0.0300
    let idHeight = 0.0225
    let columns = idCentersX.map {
      NormalizedRect(x: $0 - idWidth / 2, y: idRowsY[0] - idHeight / 2, width: idWidth, height: idHeight)
    }
    let rows = idRowsY.map {
      NormalizedRect(x: idCentersX[0] - idWidth / 2, y: $0 - idHeight / 2, width: idWidth, height: idHeight)
    }

    let markerValues: [(Double, Double, Double, Double)] = [
      (0.0631, 0.0359, 0.0330, 0.0250),
      (0.9402, 0.0359, 0.0340, 0.0250),
      (0.2025, 0.1298, 0.0310, 0.0230),
      (0.2025, 0.4886, 0.0310, 0.0230),
      (0.9715, 0.4886, 0.0300, 0.0230),
      (0.0631, 0.9460, 0.0330, 0.0250),
      (0.4886, 0.9460, 0.0340, 0.0250),
      (0.8795, 0.9460, 0.0340, 0.0250),
    ]
    let markers = markerValues.map { centerX, centerY, width, height in
      marker(centerX: centerX, centerY: centerY, width: width, height: height)
    }

    var calibration = CalibrationProfile()
    calibration.blankCenter = 0.12
    calibration.filledCenter = 0.84
    calibration.weakBoundary = 0.34
    calibration.decisionBoundary = 0.52
    calibration.minimumSelectionMargin = 0.12
    calibration.minimumMarkerCount = 4
    calibration.markerReprojectionTolerance = 0.034
    calibration.minimumLocalContrast = 0.040

    return TemplateDefinition(
      pageAspectRatio: 1054.0 / 1492.0,
      questions: questions,
      studentID: StudentIDDefinition(
        region: NormalizedRect(x: 0.500, y: 0.525, width: 0.280, height: 0.340),
        columns: columns,
        digitRows: rows,
        prefix: "320"),
      markers: markers,
      ignoredAreas: [
        NormalizedRect(x: 0.00, y: 0.08, width: 0.25, height: 0.38),
        NormalizedRect(x: 0.00, y: 0.54, width: 0.24, height: 0.33),
        NormalizedRect(x: 0.54, y: 0.30, width: 0.28, height: 0.16),
        NormalizedRect(x: 0.79, y: 0.55, width: 0.21, height: 0.20),
      ],
      calibration: calibration,
      revision: 8,
      profileName: "ArabicGeneratedPortrait-v8",
      strictRegistration: true,
      maximumAlignmentDrift: 0.105)
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
