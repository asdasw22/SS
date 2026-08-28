import Foundation
import SwiftData

@Model final class Exam {
    var id: UUID
    var name: String
    var subject: String
    var date: Date
    var maximumScore: Double
    var passingPercentage: Double
    var classroom: Classroom?
    var template: ExamTemplate?
    var answerKey: AnswerKey?
    @Relationship(deleteRule: .cascade) var questions: [Question]
    @Relationship(deleteRule: .cascade) var results: [ExamResult]
    @Relationship(deleteRule: .cascade) var scanSessions: [ScanSession]

    init(name: String, subject: String, date: Date = .now, classroom: Classroom? = nil, numberOfQuestions: Int = 20) {
        self.id = UUID(); self.name = name; self.subject = subject; self.date = date
        self.maximumScore = Double(numberOfQuestions); self.passingPercentage = 50
        self.classroom = classroom
        self.questions = numberOfQuestions > 0 ? (1...numberOfQuestions).map { Question(number: $0) } : []
        self.results = []; self.scanSessions = []
    }
}