import SwiftUI
import SwiftData

struct StudentListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Student.name) private var students: [Student]
    @State private var showingAdd = false
    @State private var search = ""
    var filtered: [Student] { search.isEmpty ? students : students.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.studentID.contains(search) } }
    var body: some View {
        NavigationStack { Group { if filtered.isEmpty { EmptyStateView(title: "No students", message: "Add students to connect scanned IDs to names.", systemImage: "person.crop.circle.badge.plus") } else { List { ForEach(filtered) { student in VStack(alignment: .leading) { Text(student.name).font(.headline); Text("\(student.studentID) · \(student.grade) · \(student.section)").font(.caption).foregroundStyle(.secondary) }.swipeActions { Button(role: .destructive) { context.delete(student); try? context.save() } label: { Label("Delete", systemImage: "trash") } } } } } }.searchable(text: $search).navigationTitle("Students").toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showingAdd = true } label: { Image(systemName: "plus") } } }.sheet(isPresented: $showingAdd) { AddStudentView() } }
    }
}

private struct AddStudentView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @State private var id = ""; @State private var name = ""; @State private var grade = "Grade 8"; @State private var section = "A"
    var body: some View { NavigationStack { Form { TextField("Student ID", text: $id).keyboardType(.numberPad); TextField("Name", text: $name); TextField("Grade", text: $grade); TextField("Section", text: $section); Button("Save Student") { context.insert(Student(studentID: id, name: name, grade: grade, section: section)); try? context.save(); dismiss() }.disabled(id.isEmpty || name.isEmpty) }.navigationTitle("New Student").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } } } }
}