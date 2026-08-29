import SwiftData
import SwiftUI
import UIKit

struct ResultDetailView: View {
  @Bindable var result: ExamResult
  let exam: Exam
  @State private var selectedAnswer: [Int: AnswerChoice] = [:]
  var body: some View {
    List {
      if let data = result.correctedImageData, let image = UIImage(data: data) {
        Section("Corrected sheet") {
          CorrectedSheetOverlay(
            image: image, result: result, template: ScannerViewModel.preparedTemplate(for: exam))
        }
      }
      Section {
        Text("\(result.score, specifier: "%.1f") / \(result.maximumScore, specifier: "%.1f")").font(
          .largeTitle.bold())
        Text("\(result.percentage, specifier: "%.1f")%").font(.title2).foregroundStyle(.secondary)
        if result.needsReview {
          Label("Needs review", systemImage: "exclamationmark.triangle.fill").foregroundStyle(
            .orange)
        }
      }
      Section("Summary") {
        LabeledContent("Correct", value: "\(result.correctCount)")
        LabeledContent("Wrong", value: "\(result.wrongCount)")
        LabeledContent("Empty", value: "\(result.emptyCount)")
        LabeledContent("Multiple", value: "\(result.multipleCount)")
      }
      Section("Answers") {
        ForEach(result.responses.sorted { $0.questionNumber < $1.questionNumber }) { response in
          ResponseEditor(response: response, result: result, exam: exam)
        }
      }
    }.navigationTitle(result.student?.name ?? result.studentID)
  }
}

private struct ResponseEditor: View {
  @Bindable var response: StudentResponse
  @Bindable var result: ExamResult
  let exam: Exam
  var body: some View {
    VStack(alignment: .leading) {
      HStack {
        Text("Q\(response.questionNumber)").font(.headline)
        Spacer()
        StatusBadge(status: response.status)
      }
      Picker(
        "Answer",
        selection: Binding(
          get: { response.selectedChoices.first?.rawValue ?? "" },
          set: { value in
            response.selectedChoices =
              value.isEmpty ? [] : AnswerChoice(rawValue: value).map { [$0] } ?? []
            response.status =
              value.isEmpty
              ? .empty : (AnswerChoice(rawValue: value) == nil ? .uncertain : .selected)
            response.manuallyEdited = true
            recalculate()
          })
      ) {
        Text("Empty").tag("")
        ForEach(
          exam.questions.first(where: { $0.number == response.questionNumber })?.choices
            ?? AnswerChoice.allCases
        ) { Text($0.rawValue).tag($0.rawValue) }
      }.pickerStyle(.segmented)
      if let correct = response.correctChoice {
        Text("Correct: \(correct.rawValue)").font(.caption).foregroundStyle(.secondary)
      }
    }
  }
  private func recalculate() {
    let weightByNumber = Dictionary(
      uniqueKeysWithValues: exam.questions.map { ($0.number, $0.weight) })
    result.correctCount =
      result.responses.filter {
        $0.status == .selected && $0.selectedChoices.first == $0.correctChoice
      }.count
    result.emptyCount = result.responses.filter { $0.status == .empty }.count
    result.multipleCount = result.responses.filter { $0.status == .multiple }.count
    result.wrongCount =
      result.responses.filter {
        !$0.selectedChoices.isEmpty
          && !($0.status == .selected && $0.selectedChoices.first == $0.correctChoice)
      }.count
    result.score = result.responses.reduce(0) {
      $0
        + ($1.status == .selected && $1.selectedChoices.first == $1.correctChoice
          ? (weightByNumber[$1.questionNumber] ?? 1) : 0)
    }
    result.percentage = result.maximumScore > 0 ? result.score / result.maximumScore * 100 : 0
  }
}
