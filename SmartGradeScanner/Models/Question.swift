import Foundation
import SwiftData

@Model final class Question {
    var id: UUID
    var number: Int
    var choicesData: Data
    var correctAnswerRaw: String?
    var weight: Double

    var choices: [AnswerChoice] {
        get { (try? JSONDecoder().decode([AnswerChoice].self, from: choicesData)) ?? AnswerChoice.allCases }
        set { choicesData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
    var correctAnswer: AnswerChoice? {
        get { correctAnswerRaw.flatMap(AnswerChoice.init(rawValue:)) }
        set { correctAnswerRaw = newValue?.rawValue }
    }

    init(number: Int, choices: [AnswerChoice] = Array(AnswerChoice.allCases), correctAnswer: AnswerChoice? = nil, weight: Double = 1) {
        self.id = UUID(); self.number = number
        self.choicesData = (try? JSONEncoder().encode(choices)) ?? Data()
        self.correctAnswerRaw = correctAnswer?.rawValue; self.weight = weight
    }
}