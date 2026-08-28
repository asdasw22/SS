import SwiftUI

import SwiftData

struct AnswerKeyView: View {

    @Bindable var exam: Exam

    @Environment(\.modelContext) private var context

    var body: some View {

        Form {

            Section { Text("Select the correct option for each question. Changes are saved with the exam.").font(.footnote).foregroundStyle(.secondary) }

            ForEach(exam.questions.sorted { $0.number < $1.number }) { question in

                Picker("Q\(question.number)", selection: Binding(get: { question.correctAnswerRaw ?? "" }, set: { question.correctAnswerRaw = $0.isEmpty ? nil : $0; syncKey() })) { Text("—").tag(""); ForEach(question.choices) { choice in Text(choice.rawValue).tag(choice.rawValue) } }.pickerStyle(.segmented)

            }

        }.navigationTitle("Answer Key")

    }

  private func syncKey() { let key = exam.answerKey ?? AnswerKey(name: "\(exam.name) Key"); if exam.answerKey == nil { context.insert(key) }; key.entries = Dictionary(uniqueKeysWithValues: exam.questions.compactMap { question in question.correctAnswer.map { choice in (question.number, choice) } }); exam.answerKey = key; try? context.save() }

}
