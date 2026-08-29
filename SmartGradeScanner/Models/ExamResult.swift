import Foundation
import SwiftData

@Model final class ExamResult {
    var id: UUID
    var scannedAt: Date
    var studentID: String
    var student: Student?
    var exam: Exam?
    var score: Double
    var maximumScore: Double
    var percentage: Double
    var correctCount: Int
    var wrongCount: Int
    var emptyCount: Int
    var multipleCount: Int
    var needsReview: Bool
    var templateProfileName: String?
    @Attribute(.externalStorage) var correctedImageData: Data?
    @Relationship(deleteRule: .cascade) var responses: [StudentResponse]

    init(omrResult: OMRProcessingResult, exam: Exam? = nil, student: Student? = nil, maximumScore: Double? = nil) {
        let finalMaximumScore = maximumScore ?? Double(max(omrResult.questions.count, 1))
        let finalScore = omrResult.earnedScore

        self.id = UUID(); self.scannedAt = .now; self.studentID = omrResult.studentID ?? "Unknown"
        self.student = student; self.exam = exam; self.score = finalScore
        self.maximumScore = finalMaximumScore
        self.percentage = finalMaximumScore > 0 ? (finalScore / finalMaximumScore) * 100 : 0
        self.correctCount = omrResult.correctCount; self.wrongCount = omrResult.wrongCount
        self.emptyCount = omrResult.emptyCount; self.multipleCount = omrResult.multipleCount
        self.needsReview = omrResult.needsReview
        self.templateProfileName = omrResult.debug?.templateProfileName
        self.correctedImageData = omrResult.alignedImageData
        self.responses = omrResult.questions.map { StudentResponse(result: $0) }
    }
}
