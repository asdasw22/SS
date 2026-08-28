import Foundation
import SwiftData

@Model final class ScanSession {
    var id: UUID
    var startedAt: Date
    var finishedAt: Date?
    var isAutomatic: Bool
    var exam: Exam?
    @Relationship(deleteRule: .cascade) var results: [ExamResult]

    init(exam: Exam? = nil, isAutomatic: Bool = true) {
        self.id = UUID(); self.startedAt = .now; self.exam = exam
        self.isAutomatic = isAutomatic; self.results = []
    }
}