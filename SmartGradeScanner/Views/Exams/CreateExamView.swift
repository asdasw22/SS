import SwiftData
import SwiftUI

struct CreateExamView: View {
  @Environment(\.dismiss) private var dismiss
  @Environment(\.modelContext) private var context
  @Query private var classrooms: [Classroom]

  @State private var name = ""
  @State private var subject = ""
  @State private var count = 20
  @State private var choiceCount = 5
  @State private var selectedClassroomID: UUID?

  var body: some View {
    NavigationStack {
      Form {
        Section("Exam details") {
          TextField("Exam name", text: $name)
          TextField("Subject", text: $subject)
          Stepper("Questions: \(count)", value: $count, in: 1...20)
        }

        Section("Answer sheet") {
          Picker("Choices per question", selection: $choiceCount) {
            Text("A-D").tag(4)
            Text("A-E").tag(5)
          }
          .pickerStyle(.segmented)

          Label(
            "Scans the fixed 904 x 1280 OMR answer sheet. Questions beyond the exam length and unused choices are ignored at scan time.",
            systemImage: "viewfinder.rectangular"
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }

        Section("Class") {
          Picker("Classroom", selection: $selectedClassroomID) {
            Text("None").tag(nil as UUID?)
            ForEach(classrooms) { classroom in
              Text(classroom.name).tag(classroom.id as UUID?)
            }
          }
        }

        Section {
          Button("Create Exam") { createExam() }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .navigationTitle("New Exam")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { dismiss() }
        }
      }
    }
  }

  private func createExam() {
    let classroom = classrooms.first { $0.id == selectedClassroomID }
    let exam = Exam(
      name: name.isEmpty ? "Untitled Exam" : name,
      subject: subject.isEmpty ? "General" : subject,
      classroom: classroom,
      numberOfQuestions: count)
    let allowedChoices = Array(AnswerChoice.allCases.prefix(choiceCount))
    for question in exam.questions {
      question.choices = allowedChoices
    }

    // One strict fixed sheet: the stored template geometry is always the 904x1280
    // layout. The exam's question count and A-D/A-E choice set are applied by
    // ScannerViewModel.adapt at scan time instead of generating a second template.
    let template = ExamTemplate(
      name: "Fixed OMR Answer Sheet",
      definition: SampleDataSeeder.fixedOMRTemplate())
    let answerKey = AnswerKey()
    exam.template = template
    exam.answerKey = answerKey

    context.insert(template)
    context.insert(answerKey)
    context.insert(exam)
    try? context.save()
    dismiss()
  }
}
