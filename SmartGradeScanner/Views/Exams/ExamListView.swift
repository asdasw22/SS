import SwiftUI
import SwiftData

struct ExamListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Exam.date, order: .reverse) private var exams: [Exam]
    @State private var showingCreate = false
    var body: some View {
        NavigationStack {
            Group { if exams.isEmpty { EmptyStateView(title: "No exams", message: "Create an exam and add its answer key to start scanning.", systemImage: "doc.text.magnifyingglass") } else { List {
                ForEach(exams) { exam in NavigationLink(destination: ExamDetailView(exam: exam)) { VStack(alignment: .leading) { Text(exam.name).font(.headline); Text("\(exam.subject) · \(exam.questions.count) questions").font(.subheadline).foregroundStyle(.secondary); Text(exam.date, style: .date).font(.caption).foregroundStyle(.secondary) } }.swipeActions { Button(role: .destructive) { context.delete(exam) } label: { Label("Delete", systemImage: "trash") } } }
            } } }.navigationTitle("Exams").toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showingCreate = true } label: { Image(systemName: "plus") } } }.sheet(isPresented: $showingCreate) { CreateExamView() }
        }
    }
}