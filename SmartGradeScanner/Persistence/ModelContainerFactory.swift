import Foundation
import SwiftData

enum ModelContainerFactory {
    static func make() throws -> ModelContainer {
        let schema = Schema([Student.self, Classroom.self, Exam.self, ExamTemplate.self,
                              Question.self, AnswerKey.self, StudentResponse.self, ExamResult.self, ScanSession.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        return try ModelContainer(for: schema, configurations: configuration)
    }
}