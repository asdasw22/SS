import CoreGraphics
import Foundation

enum AnswerChoice: String, CaseIterable, Codable, Identifiable, Sendable {
  case a = "A"
  case b = "B"
  case c = "C"
  case d = "D"
  case e = "E"

  var id: String { rawValue }
  var rank: Int {
    switch self {
    case .a: return 0
    case .b: return 1
    case .c: return 2
    case .d: return 3
    case .e: return 4
    }
  }
}

enum ResponseStatus: String, Codable, CaseIterable, Sendable {
  case selected, empty, multiple, weak, uncertain, invalidRegion
}

enum MarkerKind: String, Codable, CaseIterable, Sendable {
  case registration, rowGuide
}

enum OMRProcessingStage: String, Codable, CaseIterable, Sendable {
  case detectingPaper = "Detecting paper..."
  case checkingQuality = "Checking image quality..."
  case aligning = "Aligning template..."
  case readingStudentID = "Reading student ID..."
  case readingAnswers = "Reading answers..."
  case calculating = "Validating result..."
  case complete = "Complete"
}

struct NormalizedPoint: Codable, Equatable, Hashable, Sendable {
  var x: Double
  var y: Double

  var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

struct NormalizedRect: Codable, Equatable, Hashable, Sendable {
  var x: Double
  var y: Double
  var width: Double
  var height: Double

  var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
  var center: CGPoint { CGPoint(x: x + width / 2, y: y + height / 2) }
  var area: Double { max(0, width) * max(0, height) }
  var isInsideUnitPage: Bool {
    x >= 0 && y >= 0 && width > 0 && height > 0 && x + width <= 1 && y + height <= 1
  }

  init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  init(_ rect: CGRect, in size: CGSize) {
    let safeWidth = max(size.width, 1)
    let safeHeight = max(size.height, 1)
    self.init(
      x: rect.minX / safeWidth,
      y: rect.minY / safeHeight,
      width: rect.width / safeWidth,
      height: rect.height / safeHeight)
  }

  init(cgRect: CGRect) {
    self.init(
      x: Double(cgRect.minX),
      y: Double(cgRect.minY),
      width: Double(cgRect.width),
      height: Double(cgRect.height))
  }

  func rect(in size: CGSize) -> CGRect {
    CGRect(
      x: x * size.width,
      y: y * size.height,
      width: width * size.width,
      height: height * size.height)
  }

  func expanded(by amount: Double) -> NormalizedRect {
    NormalizedRect(
      x: x - amount,
      y: y - amount,
      width: width + amount * 2,
      height: height + amount * 2)
  }

  func intersectionRatio(with other: NormalizedRect) -> Double {
    let intersection = cgRect.intersection(other.cgRect)
    guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return 0 }
    let ownArea = max(width * height, 0.000_001)
    return Double(intersection.width * intersection.height) / ownArea
  }

  func contains(_ point: CGPoint, tolerance: Double = 0) -> Bool {
    expanded(by: tolerance).cgRect.contains(point)
  }
}

struct BubbleCoordinate: Codable, Equatable, Hashable, Sendable {
  var choice: AnswerChoice
  var rect: NormalizedRect
}

struct TemplateQuestionDefinition: Codable, Equatable, Hashable, Sendable, Identifiable {
  var id: UUID = UUID()
  var number: Int
  var bubbles: [BubbleCoordinate]
  var weight: Double = 1

  var bounds: NormalizedRect? {
    guard let first = bubbles.first else { return nil }
    let union = bubbles.dropFirst().reduce(first.rect.cgRect) { $0.union($1.rect.cgRect) }
    return NormalizedRect(cgRect: union)
  }
}

struct StudentIDDefinition: Codable, Equatable, Sendable {
  var region: NormalizedRect
  var columns: [NormalizedRect]
  var digitRows: [NormalizedRect]
  var prefix: String = ""

  var hasValidGeometry: Bool {
    guard region.isInsideUnitPage,
      !columns.isEmpty,
      digitRows.count == 10,
      columns.allSatisfy(\.isInsideUnitPage),
      digitRows.allSatisfy(\.isInsideUnitPage)
    else { return false }
    let columnCenters = columns.map { $0.center.x }
    let rowCenters = digitRows.map { $0.center.y }
    guard zip(columnCenters, columnCenters.dropFirst()).allSatisfy({ $0.0 < $0.1 }),
      zip(rowCenters, rowCenters.dropFirst()).allSatisfy({ $0.0 < $0.1 })
    else { return false }
    return columns.allSatisfy { region.expanded(by: 0.015).contains($0.center) }
      && digitRows.allSatisfy { region.expanded(by: 0.015).contains($0.center) }
  }
}

struct MarkerDefinition: Codable, Equatable, Hashable, Sendable {
  var id: UUID = UUID()
  var kind: MarkerKind
  var expectedRect: NormalizedRect
}

struct CalibrationProfile: Codable, Equatable, Sendable {
  var blankCenter: Double = 0.12
  var blankSpread: Double = 0.08
  var filledCenter: Double = 0.84
  var filledSpread: Double = 0.12
  var decisionBoundary: Double = 0.52
  var weakBoundary: Double = 0.34
  var minimumSelectionMargin: Double = 0.12
  var minimumLocalContrast: Double = 0.05
  var markerReprojectionTolerance: Double = 0.025
  var minimumMarkerCount: Int = 5
}

struct TemplateDefinition: Codable, Equatable, Sendable {
  var pageAspectRatio: Double = 591.0 / 520.0
  var questions: [TemplateQuestionDefinition] = []
  var studentID: StudentIDDefinition?
  var markers: [MarkerDefinition] = []
  var ignoredAreas: [NormalizedRect] = []
  var calibration = CalibrationProfile()
  var revision: Int = 1

  // Optional fields keep older saved templates decodable.
  var profileName: String?
  var strictRegistration: Bool?
  var maximumAlignmentDrift: Double?

  var answerBounds: NormalizedRect? {
    let rects = questions.flatMap(\.bubbles).map(\.rect)
    guard let first = rects.first else { return nil }
    let union = rects.dropFirst().reduce(first.cgRect) { $0.union($1.cgRect) }
    return NormalizedRect(cgRect: union)
  }

  var isBuiltInAutoProfile: Bool {
    guard let profileName else { return isReferenceLandscapeSheet }
    return profileName.hasPrefix("ReferenceSheet-")
      || profileName.hasPrefix("ArabicGeneratedPortrait-")
  }

  var isReferenceLandscapeSheet: Bool {
    guard let studentID else { return false }
    return pageAspectRatio > 1.05
      && pageAspectRatio < 1.22
      && studentID.columns.count == 9
      && studentID.digitRows.count == 10
      && questions.allSatisfy { (1...20).contains($0.number) }
  }

  var hasSafeSeparatedRegions: Bool {
    guard
      questions.allSatisfy({
        !$0.bubbles.isEmpty && $0.bubbles.allSatisfy { $0.rect.isInsideUnitPage }
      })
    else { return false }
    guard let studentID else { return true }
    guard studentID.hasValidGeometry else { return false }
    let protectedID = studentID.region.expanded(by: 0.006)
    return
      questions
      .flatMap(\.bubbles)
      .allSatisfy { $0.rect.intersectionRatio(with: protectedID) < 0.02 }
  }

  var validationIssues: [String] {
    var issues: [String] = []
    if !(0.2..<5.0).contains(pageAspectRatio) { issues.append("Invalid page aspect ratio") }
    if questions.isEmpty { issues.append("No question regions configured") }
    if Set(questions.map(\.number)).count != questions.count {
      issues.append("Duplicate question numbers")
    }
    if !hasSafeSeparatedRegions {
      issues.append("Question and Student ID zones overlap or leave the page")
    }
    if let studentID, !studentID.hasValidGeometry {
      issues.append("Invalid Student ID grid geometry")
    }
    if markers.contains(where: { !$0.expectedRect.isInsideUnitPage }) {
      issues.append("Registration marker outside page")
    }

    if strictRegistration == true || isReferenceLandscapeSheet {
      for question in questions {
        let ordered = question.bubbles.sorted { $0.rect.center.x < $1.rect.center.x }
        let ranks = ordered.map { $0.choice.rank }
        if ranks != ranks.sorted() {
          issues.append(
            "Question \(question.number) choice order does not match A-B-C-D-E geometry")
        }
        if Set(question.bubbles.map(\.choice)).count != question.bubbles.count {
          issues.append("Question \(question.number) contains duplicate choices")
        }
      }
    }
    return Array(Set(issues)).sorted()
  }
}

struct BubbleMeasurement: Codable, Equatable, Sendable {
  var choice: AnswerChoice
  var fillRatio: Double
  var darkness: Double
  var confidence: Double
  // Optional multi-evidence signals produced by GrayImage.bubbleEvidence(in:).
  // Older stored/template data and legacy unit tests omit these, so they default
  // to nil and BubbleClassifier gracefully falls back to fill-ratio-only logic.
  var blobFill: Double?
  var otsuFill: Double?
  var coverage: Double?
  var edgeReach: Double?
  var occupancy: Double?
  var blobCount: Double?
  var multiConsistency: Double?
}

struct OMRQuestionResult: Codable, Equatable, Sendable, Identifiable {
  var id: Int { questionNumber }
  var questionNumber: Int
  var selectedChoices: [AnswerChoice]
  var correctChoice: AnswerChoice?
  var status: ResponseStatus
  var confidence: Double
  var measurements: [BubbleMeasurement]
  var weight: Double = 1
  var isCorrect: Bool {
    status == .selected && selectedChoices.count == 1 && selectedChoices.first == correctChoice
  }
}

struct OMRDebugBubble: Codable, Equatable, Sendable, Identifiable {
  var id: String { "Q\(questionNumber)-\(choice.rawValue)" }
  var questionNumber: Int
  var choice: AnswerChoice
  var rect: NormalizedRect
  var signal: Double
  var confidence: Double
}

struct OMRDebugMarker: Codable, Equatable, Sendable, Identifiable {
  var id: Int
  var expected: NormalizedPoint
  var detected: NormalizedPoint
  var confidence: Double
}

struct OMRDebugIDCell: Codable, Equatable, Sendable, Identifiable {
  var id: String { "C\(column)-D\(digit)" }
  var column: Int
  var digit: Int
  var rect: NormalizedRect
  var signal: Double
}

struct OMRDebugSnapshot: Codable, Equatable, Sendable {
  var bubbles: [OMRDebugBubble]
  var markers: [OMRDebugMarker]
  var idCells: [OMRDebugIDCell]
  var alignmentScaleX: Double
  var alignmentScaleY: Double
  var alignmentRotationDegrees: Double
  var alignmentShear: Double
  var maximumAlignmentDrift: Double
  var questionDecisionBoundary: Double
  var studentIDDecisionBoundary: Double?
  var registrationMethod: String? = nil
  var matchedMarkerCount: Int? = nil
  var pageCandidateScore: Double? = nil
  var templateProfileName: String? = nil
}

struct OMRProcessingResult: Codable, Equatable, Sendable {
  var studentID: String?
  var questions: [OMRQuestionResult]
  var paperConfidence: Double
  var needsReview: Bool
  var warnings: [String]
  var alignedImageData: Data?
  // Fast Vision OCR lines are kept only in the transient scan result. They are used
  // to match a printed/written student name to the roster when the numeric ID is
  // missing or uncertain; ExamResult does not persist these raw OCR strings.
  var recognizedTextLines: [String] = []
  var studentIDConfidence: Double? = nil
  var debug: OMRDebugSnapshot? = nil

  var correctCount: Int { questions.filter { $0.isCorrect }.count }
  var wrongCount: Int { questions.filter { !$0.isCorrect && $0.status != .empty }.count }
  var emptyCount: Int { questions.filter { $0.status == .empty }.count }
  var multipleCount: Int { questions.filter { $0.status == .multiple }.count }
  var earnedScore: Double {
    questions.reduce(0) { $0 + ($1.isCorrect ? $1.weight : 0) }
  }
}
