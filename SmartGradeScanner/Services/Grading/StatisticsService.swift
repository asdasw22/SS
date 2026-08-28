import Foundation

struct QuestionStatistic: Identifiable {
    let id: Int
    let questionNumber: Int
    let correctPercentage: Double
    let wrongOptionCounts: [AnswerChoice: Int]
}

struct ExamStatistics {
    let studentCount: Int
    let average: Double
    let highest: Double
    let lowest: Double
    let passRate: Double
    let questions: [QuestionStatistic]
}

struct StatisticsService {
    func calculate(results: [ExamResult], passingPercentage: Double) -> ExamStatistics {
        guard !results.isEmpty else { return ExamStatistics(studentCount: 0, average: 0, highest: 0, lowest: 0, passRate: 0, questions: []) }
        let percentages = results.map { $0.percentage }
        let statistics = Dictionary(grouping: results.flatMap { $0.responses }, by: { $0.questionNumber }).map { number, responses in
            let correct = responses.filter { $0.status == .selected && $0.selectedChoices.count == 1 && $0.selectedChoices.first == $0.correctChoice }.count
            var wrong: [AnswerChoice: Int] = [:]
            responses.flatMap { $0.selectedChoices }.forEach { wrong[$0, default: 0] += 1 }
            return QuestionStatistic(id: number, questionNumber: number, correctPercentage: Double(correct) / Double(max(responses.count, 1)) * 100, wrongOptionCounts: wrong)
        }.sorted { $0.questionNumber < $1.questionNumber }
        return ExamStatistics(studentCount: results.count, average: percentages.reduce(0, +) / Double(results.count), highest: percentages.max() ?? 0, lowest: percentages.min() ?? 0, passRate: Double(percentages.filter { $0 >= passingPercentage }.count) / Double(results.count) * 100, questions: statistics)
    }
}