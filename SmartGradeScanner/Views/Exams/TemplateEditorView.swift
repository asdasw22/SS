import SwiftData
import SwiftUI
import UIKit

struct TemplateEditorView: View {
  @Environment(\.modelContext) private var context
  @Bindable var exam: Exam
  @State private var selectedQuestion: Int?
  @State private var choiceCount = 5
  @State private var statusMessage: String?

  var body: some View {
    Group {
      if UIDevice.current.userInterfaceIdiom == .pad {
        NavigationSplitView {
          controls
        } detail: {
          templatePreview
        }
      } else {
        VStack(spacing: 0) {
          templatePreview
            .frame(maxHeight: 390)
          Divider()
          controls
        }
      }
    }
    .navigationTitle("Template Editor")
    .onAppear { choiceCount = currentChoiceCount }
  }

  private var controls: some View {
    List {
      Section("Reference profile") {
        LabeledContent("Profile", value: preparedDefinition.profileName ?? "Custom")
        LabeledContent("Revision", value: "\(preparedDefinition.revision)")
        LabeledContent("Questions", value: "\(exam.questions.count)")
        LabeledContent("ID grid", value: preparedDefinition.studentID == nil ? "Off" : "9 x 10")
        LabeledContent("Markers", value: "\(preparedDefinition.markers.count)")
      }

      Section("Choices") {
        Picker("Choices", selection: $choiceCount) {
          Text("A-D").tag(4)
          Text("A-E").tag(5)
        }
        .pickerStyle(.segmented)
        Text(
          "Only these physical columns are scanned. Choosing A-D completely ignores the E column."
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }

      Section("Questions") {
        ForEach(exam.questions.sorted { $0.number < $1.number }) { question in
          Button {
            selectedQuestion = question.number
          } label: {
            HStack {
              Text("Q\(question.number)")
              Spacer()
              Text(question.choices.map(\.rawValue).joined())
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
              if selectedQuestion == question.number {
                Image(systemName: "checkmark.circle.fill")
              }
            }
          }
          .buttonStyle(.plain)
        }
      }

      Section {
        Button("Apply Reference Sheet Profile") { applyReferenceProfile() }
          .buttonStyle(.borderedProminent)
        if let statusMessage {
          Text(statusMessage)
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }

      Section("Safety") {
        Label(
          "Question bubbles and Student ID cells are separate parsers and separate calibrated zones.",
          systemImage: "lock.shield")
        Label(
          "Registration geometry is validated before any answer is accepted.", systemImage: "scope")
        Label(
          "A mismatched sheet fails instead of falling back to another template.",
          systemImage: "exclamationmark.triangle")
      }
      .font(.footnote)
    }
    .frame(minWidth: UIDevice.current.userInterfaceIdiom == .pad ? 320 : nil)
  }

  private var templatePreview: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("Physical zone preview")
            .font(.headline)
          Text("Green: answers  |  Purple: Student ID  |  Orange: registration markers")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if preparedDefinition.validationIssues.isEmpty {
          Label("Ready", systemImage: "checkmark.seal.fill")
            .foregroundStyle(.green)
        } else {
          Label("Check", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
        }
      }

      GeometryReader { geometry in
        let canvas = aspectFitRect(
          for: preparedDefinition.pageAspectRatio,
          inside: geometry.size)
        ZStack(alignment: .topLeading) {
          RoundedRectangle(cornerRadius: 12)
            .fill(Color(uiColor: .systemBackground))
            .shadow(radius: 4, y: 2)
            .frame(width: canvas.width, height: canvas.height)
            .offset(x: canvas.minX, y: canvas.minY)

          ForEach(Array(preparedDefinition.markers.enumerated()), id: \.offset) { _, marker in
            let frame = absoluteRect(marker.expectedRect, in: canvas)
            Rectangle()
              .fill(.orange.opacity(0.85))
              .frame(width: frame.width, height: frame.height)
              .offset(x: frame.minX, y: frame.minY)
          }

          ForEach(preparedDefinition.questions.sorted { $0.number < $1.number }) { question in
            ForEach(question.bubbles, id: \.self) { bubble in
              let frame = absoluteRect(bubble.rect, in: canvas)
              ZStack {
                Rectangle()
                  .stroke(
                    selectedQuestion == question.number ? .blue : .green,
                    lineWidth: selectedQuestion == question.number ? 2.2 : 1.1
                  )
                Text(bubble.choice.rawValue)
                  .font(.system(size: max(5, canvas.width * 0.009), weight: .semibold))
                  .foregroundStyle(.primary)
              }
              .frame(width: frame.width, height: frame.height)
              .offset(x: frame.minX, y: frame.minY)
            }
          }

          if let id = preparedDefinition.studentID {
            let regionFrame = absoluteRect(id.region, in: canvas)
            Rectangle()
              .stroke(.purple, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
              .frame(width: regionFrame.width, height: regionFrame.height)
              .offset(x: regionFrame.minX, y: regionFrame.minY)
            ForEach(0..<id.columns.count, id: \.self) { column in
              ForEach(0..<id.digitRows.count, id: \.self) { digit in
                if let cell = idCell(column: column, digit: digit, definition: id) {
                  let cellFrame = absoluteRect(cell, in: canvas)
                  Rectangle()
                    .stroke(.purple.opacity(0.48), lineWidth: 0.7)
                    .frame(width: cellFrame.width, height: cellFrame.height)
                    .offset(x: cellFrame.minX, y: cellFrame.minY)
                }
              }
            }
          }
        }
      }
      .aspectRatio(CGFloat(preparedDefinition.pageAspectRatio), contentMode: .fit)
      .frame(minHeight: UIDevice.current.userInterfaceIdiom == .pad ? 500 : 300)

      if !preparedDefinition.validationIssues.isEmpty {
        ForEach(preparedDefinition.validationIssues, id: \.self) { issue in
          Label(issue, systemImage: "xmark.octagon")
            .font(.footnote)
            .foregroundStyle(.red)
        }
      }
    }
    .padding()
  }

  private var currentChoiceCount: Int {
    min(max(exam.questions.first?.choices.count ?? 5, 4), 5)
  }

  private var preparedDefinition: TemplateDefinition {
    var definition = ScannerViewModel.preparedTemplate(for: exam)
    let allowed = Set(AnswerChoice.allCases.prefix(choiceCount))
    definition.questions = definition.questions.map { question in
      var copy = question
      copy.bubbles = copy.bubbles.filter { allowed.contains($0.choice) }
      return copy
    }
    return definition
  }

  private func applyReferenceProfile() {
    let allowed = Array(AnswerChoice.allCases.prefix(choiceCount))
    let allowedSet = Set(allowed)
    for question in exam.questions {
      question.choices = allowed
      if let correct = question.correctAnswer, !allowedSet.contains(correct) {
        question.correctAnswer = nil
      }
    }

    if let key = exam.answerKey {
      key.entries = key.entries.filter { allowedSet.contains($0.value) }
    } else {
      let key = AnswerKey()
      exam.answerKey = key
      context.insert(key)
    }

    let definition = SampleDataSeeder.template(
      questionCount: exam.questions.count,
      choicesPerQuestion: choiceCount)
    if let template = exam.template {
      template.name = "Reference Answer Sheet"
      template.definition = definition
    } else {
      let template = ExamTemplate(name: "Reference Answer Sheet", definition: definition)
      exam.template = template
      context.insert(template)
    }
    try? context.save()
    statusMessage = "Applied reference profile v\(definition.revision)."
  }

  private func aspectFitRect(for aspectRatio: Double, inside size: CGSize) -> CGRect {
    guard size.width > 0, size.height > 0 else { return .zero }
    let containerRatio = Double(size.width / size.height)
    if containerRatio > aspectRatio {
      let height = size.height
      let width = height * CGFloat(aspectRatio)
      return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: height)
    } else {
      let width = size.width
      let height = width / CGFloat(aspectRatio)
      return CGRect(x: 0, y: (size.height - height) / 2, width: width, height: height)
    }
  }

  private func absoluteRect(_ rect: NormalizedRect, in canvas: CGRect) -> CGRect {
    CGRect(
      x: canvas.minX + rect.x * canvas.width,
      y: canvas.minY + rect.y * canvas.height,
      width: rect.width * canvas.width,
      height: rect.height * canvas.height)
  }

  private func idCell(column: Int, digit: Int, definition: StudentIDDefinition) -> NormalizedRect? {
    guard definition.columns.indices.contains(column), definition.digitRows.indices.contains(digit)
    else { return nil }
    let columnRect = definition.columns[column]
    let rowRect = definition.digitRows[digit]
    return NormalizedRect(
      x: columnRect.x,
      y: rowRect.y,
      width: columnRect.width,
      height: rowRect.height)
  }
}
