import SwiftUI
import SwiftData

struct ClassroomListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Classroom.name) private var classrooms: [Classroom]
    @State private var add = false
    var body: some View { NavigationStack { Group { if classrooms.isEmpty { EmptyStateView(title: "No classes", message: "Create a class to organize students and exams.", systemImage: "person.2.badge.plus") } else { List { ForEach(classrooms) { classroom in VStack(alignment: .leading) { Text(classroom.name).font(.headline); Text("\(classroom.grade) · Section \(classroom.section)").font(.caption).foregroundStyle(.secondary) }.swipeActions { Button(role: .destructive) { context.delete(classroom); try? context.save() } label: { Label("Delete", systemImage: "trash") } } } } } }.navigationTitle("Classes").toolbar { ToolbarItem(placement: .topBarTrailing) { Button { add = true } label: { Image(systemName: "plus") } } }.sheet(isPresented: $add) { AddClassroomView() } } }
}

private struct AddClassroomView: View {
    @Environment(\.dismiss) private var dismiss; @Environment(\.modelContext) private var context
    @State private var name = ""; @State private var grade = "Grade 8"; @State private var section = "A"
    var body: some View { NavigationStack { Form { TextField("Class name", text: $name); TextField("Grade", text: $grade); TextField("Section", text: $section); Button("Save Class") { context.insert(Classroom(name: name, grade: grade, section: section)); try? context.save(); dismiss() }.disabled(name.isEmpty) }.navigationTitle("New Class").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } } } }
}