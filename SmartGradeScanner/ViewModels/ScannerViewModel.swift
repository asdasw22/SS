import Combine
import CoreGraphics
import Foundation
import SwiftUI
import UIKit

@MainActor final class ScannerViewModel: ObservableObject {
  @Published var stage: OMRProcessingStage = .detectingPaper
  @Published var isProcessing = false
  @Published var error: AppError?
  @Published var result: OMRProcessingResult?
  @Published var selectedImage: CGImage?

  let camera = CameraService()
  private let processor = OMRProcessor()
  let exam: Exam?
  let templateAspectRatio: Double

  init(exam: Exam? = nil) {
    self.exam = exam
    let definition = ScannerViewModel.preparedTemplate(for: exam)
    self.templateAspectRatio = definition.pageAspectRatio
    camera.liveDetector.expectedPageAspectRatio = definition.pageAspectRatio
  }

  func startCamera() async { await camera.configure() }
  func capture() { camera.capture() }

  func process(image: CGImage) {
    selectedImage = image
    guard let imageData = ImageRenderer.jpegData(from: image) else {
      error = .message("The image could not be prepared for analysis.")
      return
    }
    process(imageData: imageData)
  }

  func process(imageData: Data) {
    guard !isProcessing else { return }
    isProcessing = true
    error = nil
    result = nil

    let definition = Self.preparedTemplate(for: exam)
    guard !definition.questions.isEmpty else {
      error = .message("This exam has no question regions configured for scanning.")
      isProcessing = false
      return
    }
    guard definition.validationIssues.isEmpty else {
      error = .message("Template problem: \(definition.validationIssues.joined(separator: "; "))")
      isProcessing = false
      return
    }

    let key = exam?.answerKey?.entries ?? [:]
    let omrProcessor = processor
    stage = .detectingPaper
    let updateProgress: @MainActor @Sendable (OMRProcessingStage) -> Void = { [weak self] stage in
      self?.stage = stage
    }

    Task { [weak self, omrProcessor] in
      guard let self else { return }
      do {
        // Deliberately process exactly one selected template. Never retry a
        // different page layout after an alignment failure: that behavior can
        // turn a Student ID grid into plausible-looking A/B/C/D answers.
        let value = try await Task.detached(priority: .userInitiated) {
          try await omrProcessor.process(
            imageData: imageData,
            template: definition,
            answerKey: key,
            progress: updateProgress)
        }.value
        guard !Task.isCancelled else { return }
        self.result = value
        self.isProcessing = false
      } catch {
        self.error = .message(error.localizedDescription)
        self.isProcessing = false
      }
    }
  }

  func process(uiImage: UIImage) {
    if let image = uiImage.cgImage { selectedImage = image }
    guard let imageData = uiImage.jpegData(compressionQuality: 0.97) else {
      error = .message("The image could not be prepared for analysis.")
      return
    }
    process(imageData: imageData)
  }

  func stopCamera() { camera.stop() }

  static func preparedTemplate(for exam: Exam?) -> TemplateDefinition {
    let questionCount = min(max(exam?.questions.count ?? 20, 1), 20)
    let defaultChoiceCount = exam?.questions.first?.choices.count ?? 5

    var definition: TemplateDefinition
    if let stored = exam?.template?.definition {
      // Replace older bundled reference profiles with v6 geometry and safety
      // constraints, while leaving genuine custom templates untouched.
      if stored.isReferenceLandscapeSheet && stored.revision < 6 {
        definition = SampleDataSeeder.template(
          questionCount: questionCount,
          choicesPerQuestion: defaultChoiceCount)
      } else {
        definition = stored
      }
    } else {
      definition = SampleDataSeeder.template(
        questionCount: questionCount,
        choicesPerQuestion: defaultChoiceCount)
    }

    guard let exam else { return definition }
    let questionByNumber = Dictionary(uniqueKeysWithValues: exam.questions.map { ($0.number, $0) })
    definition.questions = definition.questions.compactMap { templateQuestion in
      guard let examQuestion = questionByNumber[templateQuestion.number] else { return nil }
      let allowedChoices = Set(examQuestion.choices)
      var copy = templateQuestion
      copy.weight = examQuestion.weight
      copy.bubbles = templateQuestion.bubbles
        .filter { allowedChoices.contains($0.choice) }
        .sorted { $0.choice.rank < $1.choice.rank }
      return copy.bubbles.count >= 2 ? copy : nil
    }
    return definition
  }
}
