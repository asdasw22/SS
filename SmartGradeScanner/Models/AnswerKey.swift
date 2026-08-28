import Foundation
import SwiftData

@Model final class AnswerKey {
    var id: UUID
    var name: String
    var entriesData: Data
    var updatedAt: Date

    var entries: [Int: AnswerChoice] {
        get { (try? JSONDecoder().decode([Int: AnswerChoice].self, from: entriesData)) ?? [:] }
        set { entriesData = (try? JSONEncoder().encode(newValue)) ?? Data(); updatedAt = .now }
    }
    init(name: String = "Answer Key", entries: [Int: AnswerChoice] = [:]) {
        self.id = UUID(); self.name = name
        self.entriesData = (try? JSONEncoder().encode(entries)) ?? Data(); self.updatedAt = .now
    }
}