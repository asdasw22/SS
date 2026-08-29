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
    guard let imageData = ImageRenderer.pngData(from: image) else {
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
        let value = try await Task.detached(priority: .userInitiated) {
          var best: (result: OMRProcessingResult, score: Double)?
          var failures: [String] = []

          // Built-in sheets are routed by evidence instead of forcing every scan
          // through one geometry. Genuine custom templates still run alone.
          for definition in definitions {
            do {
              let result = try await omrProcessor.process(
                imageData: imageData,
                template: definition,
                answerKey: key,
                progress: updateProgress)
              let score = Self.routingScore(result)
              if best.map({ score > $0.score }) ?? true {
                best = (result, score)
              }
            } catch {
              failures.append(error.localizedDescription)
            }
          }

          if let best { return best.result }
          throw OMRProcessorError.templateMismatch(
            failures.first
              ?? "No supported answer-sheet profile matched this scan. Create or select the correct template and try again.")
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
    guard let imageData = uiImage.jpegData(compressionQuality: 0.98) else {
      error = .message("The image could not be prepared for analysis.")
      return
    }
    process(imageData: imageData)
  }

  func stopCamera() { camera.stop() }

  static func candidateTemplates(for exam: Exam?) -> [TemplateDefinition] {
    let questionCount = min(max(exam?.questions.count ?? 20, 1), 20)
    let choiceCount = exam?.questions.first?.choices.count ?? 5

    if let stored = exam?.template?.definition, !stored.isBuiltInAutoProfile {
      return [adapt(template: stored, for: exam)]
    }

    let landscape = adapt(
      template: SampleDataSeeder.template(
        questionCount: questionCount,
        choicesPerQuestion: choiceCount),
      for: exam)
    let portrait = adapt(
      template: SampleDataSeeder.arabicPortraitTemplate(
        questionCount: questionCount,
        choicesPerQuestion: choiceCount),
      for: exam)
    return [landscape, portrait]
  }

  static func preparedTemplate(for exam: Exam?) -> TemplateDefinition {
    candidateTemplates(for: exam).first
      ?? SampleDataSeeder.template(questionCount: 20, choicesPerQuestion: 5)
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

  nonisolated static func routingScore(_ result: OMRProcessingResult) -> Double {
    let count = Double(max(result.questions.count, 1))
    let ambiguous = Double(result.questions.filter {
      $0.status == .multiple || $0.status == .weak || $0.status == .uncertain
        || $0.status == .invalidRegion
    }.count) / count
    let id = result.studentIDConfidence ?? (result.studentID == nil ? 0.35 : 0.80)
    let markerCount = Double(result.debug?.matchedMarkerCount ?? 0)
    let markerEvidence = min(1, markerCount / 6.0)
    let markerFirst = result.debug?.registrationMethod == "fiducialMarkers" ? 1.0 : 0.0
    let candidate = min(1, max(0, result.debug?.pageCandidateScore ?? 0.45))
    let alignment = min(1, max(0, result.debug?.alignmentConfidence ?? result.paperConfidence))
    let coverage = min(1, max(0, (result.debug?.markerCoverage ?? 0) / 0.28))
    let reprojection = result.debug?.reprojectionError ?? 0.05
    let reprojectionEvidence = reprojection.isFinite
      ? max(0, 1 - reprojection / 0.075)
      : 0

    // Never reward a profile merely because it produced many answers. A completely
    // blank exam is valid, and a wrong template can manufacture confident-looking
    // marks. Routing is based on page/marker geometry and signal integrity instead.
    var score = result.paperConfidence * 0.21
      + alignment * 0.19
      + markerEvidence * 0.17
      + coverage * 0.11
      + reprojectionEvidence * 0.10
      + max(0, 1 - ambiguous) * 0.09
      + id * 0.05
      + markerFirst * 0.04
      + candidate * 0.04

    // A built-in profile that found fewer than four registration squares must not
    // beat a profile that actually matches the printed geometry.  This was the
    // source of the visibly squeezed preview and bizarre answer coordinates.
    if markerCount < 4 && markerFirst == 0 { score -= 0.30 }
    return min(1, max(0, score))
  }

}
