import SwiftUI
import UIKit

struct CorrectedSheetOverlay: View {
    let image: UIImage
    let result: ExamResult
    let template: TemplateDefinition?
    @State private var selectedQuestion: Int?

    private var imageAspectRatio: Double {
        Double(image.size.width / max(image.size.height, 1))
    }

    var body: some View {
        GeometryReader { proxy in
            let fitted = aspectFitRect(aspectRatio: imageAspectRatio, in: proxy.size)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: fitted.width, height: fitted.height)

                if let template {
                    ForEach(result.responses) { response in
                        if let question = template.questions.first(where: { $0.number == response.questionNumber }) {
                            let rect = normalizedBounds(for: question, in: fitted.size)
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(color(for: response.status), lineWidth: selectedQuestion == response.questionNumber ? 4 : 2)
                                .frame(width: rect.width, height: rect.height)
                                .position(x: rect.midX, y: rect.midY)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedQuestion = response.questionNumber }
                        }
                    }
                }
            }
            .frame(width: fitted.width, height: fitted.height)
            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
        }
        .aspectRatio(CGFloat(imageAspectRatio), contentMode: .fit)
        .sheet(item: Binding(get: {
            selectedQuestion.map { QuestionSelection(number: $0) }
        }, set: {
            selectedQuestion = $0?.number
        })) { selection in
            if let response = result.responses.first(where: { $0.questionNumber == selection.number }) {
                VStack(spacing: 12) {
                    Text("Question \(selection.number)").font(.title2.bold())
                    Text("Student: \(response.selectedChoices.map { $0.rawValue }.joined(separator: " + ").ifEmpty("Empty"))")
                    Text("Correct: \(response.correctChoice?.rawValue ?? "—")").foregroundStyle(.secondary)
                    Text("Confidence: \(response.confidence * 100, specifier: "%.0f")%").foregroundStyle(.secondary)
                    Spacer()
                }
                .padding()
                .presentationDetents([.medium])
            }
        }
    }

    private func normalizedBounds(for question: TemplateQuestionDefinition, in size: CGSize) -> CGRect {
        guard let first = question.bubbles.first else { return .zero }
        let union = question.bubbles.dropFirst().reduce(first.rect.cgRect) { $0.union($1.rect.cgRect) }
        return CGRect(x: union.minX * size.width,
                      y: union.minY * size.height,
                      width: union.width * size.width,
                      height: union.height * size.height)
    }

    private func aspectFitRect(aspectRatio: Double, in size: CGSize) -> CGRect {
        let ratio = CGFloat(max(aspectRatio, 0.01))
        let containerRatio = size.width / max(size.height, 1)
        if containerRatio > ratio {
            let height = size.height
            let width = height * ratio
            return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: height)
        } else {
            let width = size.width
            let height = width / ratio
            return CGRect(x: 0, y: (size.height - height) / 2, width: width, height: height)
        }
    }

    private func color(for status: ResponseStatus) -> Color {
        switch status {
        case .selected: return .green
        case .empty: return .gray
        case .multiple: return .red
        default: return .orange
        }
    }
}

private struct QuestionSelection: Identifiable {
    let number: Int
    var id: Int { number }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
