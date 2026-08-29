import SwiftUI
import SwiftData

struct StudentListView: View {
  @Environment(\.modelContext) private var context
  @Query(sort: \Student.name) private var students: [Student]
  @State private var showingAdd = false
  @State private var search = ""

  var filtered: [Student] {
    search.isEmpty
      ? students
      : students.filter {
          $0.name.localizedCaseInsensitiveContains(search) || $0.studentID.contains(search)
        }
  }

  var body: some View {
    NavigationStack {
      Group {
        if filtered.isEmpty {
          EmptyStateView(
            title: "No students",
            message: "Add students to connect scanned IDs to names and saved exam marks.",
            systemImage: "person.crop.circle.badge.plus")
        } else {
          List {
            ForEach(filtered) { student in
              NavigationLink(destination: StudentDetailView(student: student)) {
                VStack(alignment: .leading, spacing: 4) {
                  Text(student.name).font(.headline)
                  Text("\(student.studentID) · \(student.grade) · \(student.section)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
              }
              .swipeActions {
                Button(role: .destructive) {
                  context.delete(student)
                  try? context.save()
                } label: {
                  Label("Delete", systemImage: "trash")
                }
              }
            }
          }
        }
      }
      .searchable(text: $search)
      .navigationTitle("Students")
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button { showingAdd = true } label: { Image(systemName: "plus") }
        }
      }
      .sheet(isPresented: $showingAdd) { AddStudentView() }
    }
  }
}

private struct StudentDetailView: View {
  let student: Student
  @Query(sort: \ExamResult.scannedAt, order: .reverse) private var allResults: [ExamResult]

  private var results: [ExamResult] {
    let id = canonicalStudentID(student.studentID)
    return allResults.filter { result in
      if result.student?.id == student.id { return true }
      return !id.isEmpty && canonicalStudentID(result.studentID) == id
    }
  }

  var body: some View {
    List {
      Section("Student") {
        LabeledContent("ID", value: student.studentID)
        LabeledContent("Class", value: "\(student.grade) · \(student.section)")
      }

      Section("Saved marks") {
        if results.isEmpty {
          Text("No saved exam marks yet")
            .foregroundStyle(.secondary)
        } else {
          ForEach(results) { result in
            VStack(alignment: .leading, spacing: 5) {
              HStack {
                Text(result.exam?.name ?? "Exam")
                  .font(.headline)
                Spacer()
                Text(result.percentage.formatted(.number.precision(.fractionLength(0))) + "%")
                  .font(.headline)
              }
              Text(
                "\(result.score.formatted(.number.precision(.fractionLength(0...2)))) / \(result.maximumScore.formatted(.number.precision(.fractionLength(0...2))))"
              )
              .font(.subheadline)
              Text(result.scannedAt, format: .dateTime.day().month().year().hour().minute())
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 3)
          }
        }
      }
    }
    .navigationTitle(student.name)
  }

  private func canonicalStudentID(_ value: String) -> String {
    value.compactMap { $0.wholeNumberValue }.map { String($0) }.joined()
  }
}

private struct AddStudentView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var context
  @State private var id = ""
  @State private var name = ""
  @State private var grade = "Grade 8"
  @State private var section = "A"

  var body: some View {
    NavigationStack {
      Form {
        TextField("Student ID", text: $id).keyboardType(.numberPad)
        TextField("Name", text: $name)
        TextField("Grade", text: $grade)
        TextField("Section", text: $section)
        Button("Save Student") {
          context.insert(
            Student(studentID: id, name: name, grade: grade, section: section))
          try? context.save()
          dismiss()
        }
        .disabled(id.isEmpty || name.isEmpty)
      }
      .navigationTitle("New Student")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
  }
}
