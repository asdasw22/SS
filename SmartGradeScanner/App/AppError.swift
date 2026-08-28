import Foundation

enum AppError: LocalizedError, Identifiable {
    case message(String)
    var id: String { localizedDescription }
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}