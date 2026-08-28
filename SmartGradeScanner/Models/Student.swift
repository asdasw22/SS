import Foundation
import SwiftData

@Model final class Student {
    var id: UUID
    var studentID: String
    var name: String
    var grade: String
    var section: String
    var classroom: Classroom?
    var createdAt: Date

    init(studentID: String, name: String, grade: String, section: String, classroom: Classroom? = nil) {
        self.id = UUID(); self.studentID = studentID; self.name = name
        self.grade = grade; self.section = section; self.classroom = classroom; self.createdAt = .now
    }
}