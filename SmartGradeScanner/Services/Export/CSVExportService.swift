import Foundation

struct CSVExportService: Sendable {
    func export(results: [ExamResult]) -> URL? {
        let rows = ["Student ID,Name,Score,Maximum,Percentage,Correct,Wrong,Empty,Multiple"] + results.map { result in
            let name = result.student?.name ?? ""
            return [result.studentID, name, String(format: "%.2f", result.score), String(format: "%.2f", result.maximumScore), String(format: "%.2f", result.percentage), "\(result.correctCount)", "\(result.wrongCount)", "\(result.emptyCount)", "\(result.multipleCount)"].map(escape).joined(separator: ",")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SmartGrade-Results-\(UUID().uuidString).csv")
        do { try rows.joined(separator: "\n").data(using: .utf8)?.write(to: url); return url } catch { return nil }
    }

    private func escape(_ value: String) -> String { "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\"" }
}