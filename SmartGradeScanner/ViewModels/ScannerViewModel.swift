import Combine
import CoreGraphics
import Foundation
import SwiftUI
import UIKit

@MainActor final class ScannerViewModel: ObservableObject {
  @Published var stage: OMRProcessingStage = .detectingPaper
  @Published var isProcessing = false
  @Published var isCapturing = false
  @Published var error: AppError?
  @Published var result: OMRProcessingResult?
  @Published var selectedImage: CGImage?

  let camera = CameraService()
  private let processor = OMRProcessor()
  let exam: Exam?
  let templateAspectRatio: Double

  init(exam: Exam? = nil) {
    self.exam = exam
    let definitions = ScannerViewModel.candidateTemplates(for: exam)
    self.templateAspectRatio = definitions.count > 1
      ? 1.0
      : (definitions.first?.pageAspectRatio ?? 1.0)
  }

  func startCamera() async { await camera.configure() }

  func capture() {
    guard !isProcessing, !isCapturing else { return }
    isCapturing = true
    error = nil
    Task { [weak self] in
      guard let self else { return }
      let didCapture = await self.camera.captureWhenReady()
      if !didCapture {
        self.isCapturing = false
        self.error = .message(
          "Camera is not ready. Allow camera access and try again, or use Document Scanner / Photos.")
      }
    }
  }

  func process(image: CGImage) {
    selectedImage = image
    guard let imageData = ImageRenderer.jpegData(from: image) else {
      error = .message("The image could not be prepared for analysis.")
      return
    }
    process(imageData: imageData)
  }

  func process(imageData: Data) {
    isCapturing = false
    guard !isProcessing else { return }
    isProcessing = true
    error = nil
    result = nil

    let definitions = Self.candidateTemplates(for: exam)
    guard !definitions.isEmpty, definitions.allSatisfy({ !$0.questions.isEmpty }) else {
      error = .message("This exam has no question regions configured for scanning.")
      isProcessing = false
      return
    }
    if let invalid = definitions.first(where: { !$0.validationIssues.isEmpty }) {
      error = .message("Template problem: \(invalid.validationIssues.joined(separator: "; "))")
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
        // Strict fixed-sheet mode: exactly ONE template exists
        // (FixedOMR-904x1280-Strict-v10). There is deliberately no profile
        // competition, no best-score routing and no second candidate: the page
        // registers against this single geometry or the scan is rejected
        // (TEMPLATE_ALIGNMENT_FAILED / RESCAN_REQUIRED). Scoring several layouts
        // and keeping the winner was legacy guessing behavior and was removed.
        let value = try await Task.detached(priority: .userInitiated) {
          try await omrProcessor.process(
            imageData: imageData,
            template: definitions[0],
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

  static func candidateTemplates(for exam: Exam?) -> [TemplateDefinition] {
    if let stored = exam?.template?.definition, !stored.isBuiltInAutoProfile {
      return [adapt(template: stored, for: exam)]
    }
    // Fixed sheet mode: exactly one template geometry (904×1280, 20 questions × 5
    // choices). There is no competing profile and no "best guess" routing; the
    // sheet either registers against this one layout or the scan is refused.
    return [adapt(template: SampleDataSeeder.fixedOMRTemplate(), for: exam)]
  }

  static func preparedTemplate(for exam: Exam?) -> TemplateDefinition {
    candidateTemplates(for: exam).first
      ?? SampleDataSeeder.fixedOMRTemplate()
  }

  private static func adapt(template: TemplateDefinition, for exam: Exam?) -> TemplateDefinition {
    var definition = template
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

  nonisolated private static func routingScore(_ result: OMRProcessingResult) -> Double {
    // REMOVED (strict fixed-sheet v10): template routing by best score was a
    // guessing path. The fixed sheet uses exactly one template; the processor
    // either registers the page against it or rejects the scan.
    return 0
  }

}
