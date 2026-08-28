import Foundation
import SwiftData
import Combine

@MainActor final class StudentsViewModel: ObservableObject {
    func delete(_ student: Student, from context: ModelContext) { context.delete(student); try? context.save() }
}