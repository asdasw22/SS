import Foundation
import SwiftData
import Combine

@MainActor final class HomeViewModel: ObservableObject {
    func totalStudents(_ students: [Student]) -> Int { students.count }
    func totalExams(_ exams: [Exam]) -> Int { exams.count }
    func totalScans(_ exams: [Exam]) -> Int { exams.reduce(0) { $0 + $1.results.count } }
}