import Foundation
import CoreGraphics
import PDFKit
import UIKit

struct PDFReportService {
    func export(exam: Exam, results: [ExamResult], statistics: ExamStatistics) -> URL? {
        let document = PDFDocument(); let pageBounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds)
        let data = renderer.pdfData { context in
            context.beginPage(); let title = "\(exam.name)\n\(exam.subject)\n\nStudents: \(statistics.studentCount)    Average: \(String(format: "%.1f", statistics.average))%\nPass rate: \(String(format: "%.1f", statistics.passRate))%\n\n"
            title.draw(in: CGRect(x: 36, y: 36, width: 540, height: 110), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 18)])
            var y: CGFloat = 160
            for result in results.prefix(30) {
                let line = "\(result.studentID)  \(result.student?.name ?? "")  \(String(format: "%.1f", result.score))/\(String(format: "%.1f", result.maximumScore))  \(String(format: "%.1f", result.percentage))%"
                line.draw(in: CGRect(x: 36, y: y, width: 540, height: 22), withAttributes: [.font: UIFont.systemFont(ofSize: 11)]); y += 22
                if y > 750 { break }
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SmartGrade-Report-\(UUID().uuidString).pdf")
        do { try data.write(to: url); _ = document; return url } catch { return nil }
    }
}