import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct ScannerView: View {
  @Environment(\.modelContext) private var context
  @StateObject private var viewModel: ScannerViewModel
  @State private var selectedPhoto: PhotosPickerItem?

  init(exam: Exam? = nil) {
    _viewModel = StateObject(wrappedValue: ScannerViewModel(exam: exam))
  }

  var body: some View {
    ZStack {
      CameraPreview(session: viewModel.camera.session).ignoresSafeArea()
      VStack {
        HStack {
          Label(viewModel.exam?.name ?? "Quick Scan", systemImage: "doc.text")
            .padding(10)
            .background(.ultraThinMaterial, in: Capsule())
          Spacer()
          PhotosPicker(selection: $selectedPhoto, matching: .images) {
            Image(systemName: "photo.on.rectangle")
              .font(.title3)
              .padding(10)
              .background(.ultraThinMaterial, in: Circle())
          }
        }
        .padding()
        Spacer()
        scanGuide
        controls
      }
    }
    .navigationTitle("Scan")
    .navigationBarTitleDisplayMode(.inline)
    .task { await viewModel.startCamera() }
    .onDisappear { viewModel.stopCamera() }
    .onReceive(viewModel.camera.$lastImageData.compactMap { $0 }) { imageData in
      viewModel.process(imageData: imageData)
    }
    .onChange(of: selectedPhoto) { _, item in
      guard let item else { return }
      Task {
        if let data = try? await item.loadTransferable(type: Data.self) {
          viewModel.process(imageData: data)
        }
      }
    }
    .sheet(
      isPresented: Binding(
        get: {
          viewModel.result != nil && !viewModel.isProcessing
        },
        set: {
          if !$0 { viewModel.result = nil }
        })
    ) {
      if let result = viewModel.result {
        ScanReviewView(result: result, exam: viewModel.exam, context: context)
      }
    }
    .alert(item: $viewModel.error) { error in
      Alert(
        title: Text("Scan failed"),
        message: Text(error.localizedDescription),
        dismissButton: .default(Text("OK")))
    }
  }

  private var scanGuide: some View {
    RoundedRectangle(cornerRadius: 22)
      .stroke(
        viewModel.isProcessing
          ? .orange : (viewModel.camera.liveDetector.isReady ? .green : .white),
        style: StrokeStyle(lineWidth: 3, dash: [10])
      )
      .frame(maxWidth: 520)
      .aspectRatio(CGFloat(viewModel.templateAspectRatio), contentMode: .fit)
      .padding(24)
      .overlay(alignment: .bottom) {
        Text(
          viewModel.isProcessing
            ? viewModel.stage.rawValue
            : (viewModel.camera.liveDetector.isReady
              ? "Ready - tap the shutter"
              : "Keep the WHOLE sheet and all black registration squares inside the frame. No manual edge selection is needed.")
        )
        .font(.headline)
        .multilineTextAlignment(.center)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.68), in: Capsule())
        .padding(.bottom, 36)
      }
  }

  private var controls: some View {
    HStack(spacing: 28) {
      Label("Fast OMR", systemImage: "viewfinder")
        .font(.headline)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundStyle(.white)

      Button {
        viewModel.capture()
      } label: {
        Image(systemName: "circle.fill")
          .font(.system(size: 64))
          .foregroundStyle(.white)
          .overlay { Circle().stroke(.black.opacity(0.3), lineWidth: 2) }
      }
      .disabled(viewModel.isProcessing)

      Spacer().frame(width: 90)
    }
    .padding(.horizontal, 24)
    .padding(.bottom, 22)
  }
}

private struct ScanReviewView: View {
  let result: OMRProcessingResult
  let exam: Exam?
  let context: ModelContext
  @Environment(\.dismiss) private var dismiss
  @AppStorage("debugMode") private var debugMode = false
  @State private var flaggedOnly = false

  private var visibleQuestions: [OMRQuestionResult] {
    let sorted = result.questions.sorted { $0.questionNumber < $1.questionNumber }
    guard flaggedOnly else { return sorted }
    return sorted.filter { $0.status != .selected || $0.confidence < 0.72 }
  }

  var body: some View {
    NavigationStack {
      List {
        if let data = result.alignedImageData, let image = UIImage(data: data) {
          Section("Aligned sheet") {
            ScanDebugPreview(
              image: image,
              debug: debugMode ? result.debug : nil,
              template: ScannerViewModel.preparedTemplate(for: exam)
            )
            .frame(minHeight: 260)
          }
        }

        Section("Detection") {
          LabeledContent("Student ID", value: result.studentID ?? "Needs review")
          if let confidence = result.studentIDConfidence {
            LabeledContent(
              "ID confidence", value: confidence.formatted(.percent.precision(.fractionLength(0))))
          }
          LabeledContent(
            "Detected answers",
            value: "\(result.questions.count) / \(exam?.questions.count ?? result.questions.count)")
          LabeledContent(
            "Paper confidence",
            value: result.paperConfidence.formatted(.percent.precision(.fractionLength(0))))
          if result.needsReview {
            Label("Some fields need manual review", systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          } else {
            Label(
              "Registration and answer zones passed validation",
              systemImage: "checkmark.shield.fill"
            )
            .foregroundStyle(.green)
          }
        }

        if let debug = result.debug, debugMode {
          Section("OMR diagnostics") {
            LabeledContent(
              "Question threshold",
              value: debug.questionDecisionBoundary.formatted(.number.precision(.fractionLength(3)))
            )
            if let threshold = debug.studentIDDecisionBoundary {
              LabeledContent(
                "Student ID threshold",
                value: threshold.formatted(.number.precision(.fractionLength(3))))
            }
            LabeledContent(
              "Scale X",
              value: debug.alignmentScaleX.formatted(.number.precision(.fractionLength(3))))
            LabeledContent(
              "Scale Y",
              value: debug.alignmentScaleY.formatted(.number.precision(.fractionLength(3))))
            LabeledContent(
              "Rotation", value: debug.alignmentRotationDegrees.formatted(.number.precision(.fractionLength(2))) + " deg")
            LabeledContent(
              "Max drift",
              value: debug.maximumAlignmentDrift.formatted(.number.precision(.fractionLength(4))))
          }
        }

        if !result.warnings.isEmpty {
          Section("Checks") {
            ForEach(result.warnings, id: \.self) { warning in
              Label(warning, systemImage: "info.circle")
                .font(.footnote)
            }
          }
        }

        Section {
          Toggle("Review flagged only", isOn: $flaggedOnly)
        }

        Section("Questions") {
          ForEach(visibleQuestions) { item in
            VStack(alignment: .leading, spacing: 7) {
              HStack {
                Text("Q\(item.questionNumber)")
                  .font(.headline)
                  .frame(width: 44, alignment: .leading)
                Text(item.selectedChoices.map(\.rawValue).joined(separator: " + ").ifEmpty("Empty"))
                  .font(.headline.monospaced())
                Spacer()
                StatusBadge(status: item.status)
              }
              HStack {
                Text("Correct: \(item.correctChoice?.rawValue ?? "-")")
                Spacer()
                Text("Confidence \(item.confidence * 100, specifier: "%.0f")%")
              }
              .font(.caption)
              .foregroundStyle(.secondary)

              if debugMode {
                Text(
                  item.measurements
                    .sorted { $0.choice.rank < $1.choice.rank }
                    .map { "\($0.choice.rawValue)=\(String(format: "%.3f", $0.fillRatio))" }
                    .joined(separator: "   ")
                )
                .font(.caption2.monospaced())
                .textSelection(.enabled)
              }
            }
            .padding(.vertical, 3)
          }
        }

        Section {
          Button("Save Result") { saveResult() }
            .buttonStyle(.borderedProminent)
        }
      }
      .navigationTitle("Review Scan")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Discard") { dismiss() }
        }
      }
    }
  }

  private func saveResult() {
    let student = result.studentID.flatMap { id in
      (try? context.fetch(FetchDescriptor<Student>()))?.first { $0.studentID == id }
    }
    let model = ExamResult(
      omrResult: result,
      exam: exam,
      student: student,
      maximumScore: exam?.maximumScore)
    if let exam { exam.results.append(model) }
    context.insert(model)
    try? context.save()
    dismiss()
  }
}

private struct ScanDebugPreview: View {
  let image: UIImage
  let debug: OMRDebugSnapshot?
  let template: TemplateDefinition

  var body: some View {
    GeometryReader { proxy in
      let fitted = aspectFitRect(aspectRatio: template.pageAspectRatio, in: proxy.size)
      ZStack(alignment: .topLeading) {
        Image(uiImage: image)
          .resizable()
          .frame(width: fitted.width, height: fitted.height)
          .offset(x: fitted.minX, y: fitted.minY)

        if let debug {
          ForEach(debug.bubbles) { bubble in
            let frame = absoluteRect(bubble.rect, in: fitted)
            ZStack(alignment: .topLeading) {
              Rectangle()
                .stroke(
                  bubble.signal >= debug.questionDecisionBoundary ? .green : .blue.opacity(0.6),
                  lineWidth: 1
                )
              Text(
                "Q\(bubble.questionNumber)\(bubble.choice.rawValue) \(bubble.signal, specifier: "%.2f")"
              )
              .font(.system(size: 6, weight: .bold, design: .monospaced))
              .foregroundStyle(.white)
              .background(.black.opacity(0.75))
              .offset(y: -7)
            }
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
          }

          if let id = template.studentID {
            let frame = absoluteRect(id.region, in: fitted)
            Rectangle()
              .stroke(.purple, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
              .frame(width: frame.width, height: frame.height)
              .offset(x: frame.minX, y: frame.minY)
          }

          ForEach(debug.markers) { marker in
            Circle()
              .stroke(.orange, lineWidth: 2)
              .frame(width: 9, height: 9)
              .position(
                x: fitted.minX + marker.detected.x * fitted.width,
                y: fitted.minY + marker.detected.y * fitted.height)
          }
        }
      }
    }
    .aspectRatio(CGFloat(template.pageAspectRatio), contentMode: .fit)
    .clipShape(RoundedRectangle(cornerRadius: 12))
  }

  private func absoluteRect(_ rect: NormalizedRect, in fitted: CGRect) -> CGRect {
    CGRect(
      x: fitted.minX + rect.x * fitted.width,
      y: fitted.minY + rect.y * fitted.height,
      width: rect.width * fitted.width,
      height: rect.height * fitted.height)
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
}

extension String {
  fileprivate func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
