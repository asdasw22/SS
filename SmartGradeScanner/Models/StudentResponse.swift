import Foundation
import SwiftData

@Model final class StudentResponse {
    var id: UUID
    var questionNumber: Int
    var selectedChoicesData: Data
    var correctChoiceRaw: String?
    var statusRaw: String
    var confidence: Double
    var fillRatiosData: Data
    var detectedBoundsData: Data?
    var manuallyEdited: Bool

    var selectedChoices: [AnswerChoice] {
        get { (try? JSONDecoder().decode([AnswerChoice].self, from: selectedChoicesData)) ?? [] }
        set { selectedChoicesData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
    var correctChoice: AnswerChoice? {
        get { correctChoiceRaw.flatMap(AnswerChoice.init(rawValue:)) }
        set { correctChoiceRaw = newValue?.rawValue }
    }
    var status: ResponseStatus {
        get { ResponseStatus(rawValue: statusRaw) ?? .uncertain }
        set { statusRaw = newValue.rawValue }
    }
    var fillRatios: [String: Double] {
        get { (try? JSONDecoder().decode([String: Double].self, from: fillRatiosData)) ?? [:] }
        set { fillRatiosData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
    var detectedBounds: NormalizedRect? {
        get {
            guard let detectedBoundsData else { return nil }
            return try? JSONDecoder().decode(NormalizedRect.self, from: detectedBoundsData)
        }
        set { detectedBoundsData = try? JSONEncoder().encode(newValue) }
    }
    init(result: OMRQuestionResult) {
        self.id = UUID(); self.questionNumber = result.questionNumber
        self.selectedChoicesData = (try? JSONEncoder().encode(result.selectedChoices)) ?? Data()
        self.correctChoiceRaw = result.correctChoice?.rawValue; self.statusRaw = result.status.rawValue
        self.confidence = result.confidence
        self.fillRatiosData = (try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: result.measurements.map { ($0.choice.rawValue, $0.fillRatio) }))) ?? Data()
        self.detectedBoundsData = try? JSONEncoder().encode(result.detectedBounds)
        self.manuallyEdited = false
    }
}
