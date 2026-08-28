import Foundation

struct GradingService: Sendable {
    func recalculate(questions: [OMRQuestionResult], answerKey: [Int: AnswerChoice]) -> OMRProcessingResult {
        let revised = questions.map { item in
            var copy = item; copy.correctChoice = answerKey[item.questionNumber]; return copy
        }
        return OMRProcessingResult(studentID: nil, questions: revised, paperConfidence: 1, needsReview: revised.contains { $0.status == .weak || $0.status == .uncertain || $0.status == .multiple }, warnings: [], alignedImageData: nil)
    }
}