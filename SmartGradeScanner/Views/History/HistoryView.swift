import SwiftUI
import SwiftData

struct HistoryView: View {
    @Query(sort: \Exam.date, order: .reverse) private var exams: [Exam]
    var body: some View { NavigationStack { List { ForEach(exams) { exam in Section { NavigationLink(destination: ExamDetailView(exam: exam)) { VStack(alignment: .leading) { Text(exam.name).font(.headline); Text("\(exam.date, format: .dateTime.day().month().year()) · \(exam.results.count) students").font(.caption).foregroundStyle(.secondary) } } } } }.navigationTitle("History") } }
}