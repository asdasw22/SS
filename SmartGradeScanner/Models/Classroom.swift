import Foundation
import SwiftData

@Model final class Classroom {
    var id: UUID
    var name: String
    var grade: String
    var section: String
    var createdAt: Date

    init(name: String, grade: String, section: String) {
        self.id = UUID(); self.name = name; self.grade = grade; self.section = section; self.createdAt = .now
    }
}