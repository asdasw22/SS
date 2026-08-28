import SwiftUI
import SwiftData
import UIKit
import Foundation

struct ExamDetailView: View {
    @Environment(\.modelContext) private var context
    @Bindable var exam: Exam
    @State private var pdfURL: ExportedFile?
    var body: some View {
        List {
            Section { LabeledContent("Subject", value: exam.subject); LabeledContent("Questions", value: "\(exam.questions.count)"); LabeledContent("Results", value: "\(exam.results.count)") }
            Section("Answer key") { NavigationLink("Edit Answer Key") { AnswerKeyView(exam: exam) }; NavigationLink("Edit Template") { TemplateEditorView(exam: exam) } }
            Section("Results") { if exam.results.isEmpty { Text("No scanned students yet").foregroundStyle(.secondary) } else { ForEach(exam.results) { result in NavigationLink(destination: ResultDetailView(result: result, exam: exam)) { HStack { VStack(alignment: .leading) { Text(result.student?.name ?? result.studentID); Text(result.scannedAt, style: .date).font(.caption).foregroundStyle(.secondary) }; Spacer(); Text("\(result.percentage, specifier: "%.0f")%").font(.headline) } } } } }
        }.navigationTitle(exam.name).toolbar { ToolbarItemGroup(placement: .topBarTrailing) { Button { if let url = PDFReportService().export(exam: exam, results: exam.results, statistics: StatisticsService().calculate(results: exam.results, passingPercentage: exam.passingPercentage)) { pdfURL = ExportedFile(url: url) } } label: { Image(systemName: "doc.richtext") }; if let csvURL = CSVExportService().export(results: exam.results) { ShareLink(item: csvURL) { Image(systemName: "square.and.arrow.up") } }; NavigationLink(destination: ScannerView(exam: exam)) { Image(systemName: "camera.viewfinder") } } }.sheet(item: $pdfURL) { file in ActivityView(activityItems: [file.url]) }
    }
}

private struct ExportedFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: activityItems, applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}