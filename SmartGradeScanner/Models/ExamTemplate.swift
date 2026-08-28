import Foundation
import SwiftData

@Model final class ExamTemplate {
    var id: UUID
    var name: String
    @Attribute(.externalStorage) var referenceImageData: Data?
    var definitionData: Data
    var createdAt: Date

    var definition: TemplateDefinition {
        get { (try? JSONDecoder().decode(TemplateDefinition.self, from: definitionData)) ?? TemplateDefinition() }
        set { definitionData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }
    init(name: String, definition: TemplateDefinition = TemplateDefinition(), referenceImageData: Data? = nil) {
        self.id = UUID(); self.name = name
        self.definitionData = (try? JSONEncoder().encode(definition)) ?? Data()
        self.referenceImageData = referenceImageData; self.createdAt = .now
    }
}