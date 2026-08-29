import PhotosUI
import SwiftData
import SwiftUI
import UIKit

struct ScannerView: View {
  @Environment(\.modelContext) private var context
  @StateObject private var viewModel: ScannerViewModel
  @State private var selectedPhoto: PhotosPickerItem?
  @State private var showDocumentScanner = false

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
          HStack(spacing: 10) {
            Button {
              showDocumentScanner = true
            } label: {
              Image(systemName: "doc.viewfinder")
                .font(.title3)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Document Scanner")

            PhotosPicker(selection: $selectedPhoto, matching: .images) {
              Image(systemName: "photo.on.rectangle")
                .font(.title3)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
            }
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
    .fullScreenCover(isPresented: $showDocumentScanner) {
      DocumentScannerView(
        onImageData: { data in
          showDocumentScanner = false
          viewModel.process(imageData: data)
        },
        onCancel: {
          showDocumentScanner = false
        })
        .ignoresSafeArea()
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
            : (viewModel.isCapturing
              ? "Capturing high-quality image..."
              : (viewModel.camera.liveDetector.isReady
                ? "Ready - tap Fast OMR"
                : "Keep the sheet reasonably inside the frame. Tap Fast OMR even if the border is not green; marker-first registration will try the black squares automatically."))
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
    HStack(spacing: 22) {
      Button {
        viewModel.capture()
      } label: {
        Label(viewModel.isProcessing ? "Analyzing..." : (viewModel.isCapturing ? "Capturing..." : "Fast OMR"), systemImage: "viewfinder")
          .font(.headline)
          .padding(.horizontal, 16)
          .padding(.vertical, 11)
          .background(.ultraThinMaterial, in: Capsule())
          .foregroundStyle(.white)
      }
      .buttonStyle(.plain)
      .disabled(viewModel.isProcessing || viewModel.isCapturing)
      .accessibilityHint("Captures immediately. A green page-border indicator is not required.")

      Button {
        viewModel.capture()
      } label: {
        Image(systemName: "circle.fill")
          .font(.system(size: 64))
          .foregroundStyle(.white)
          .overlay { Circle().stroke(.black.opacity(0.3), lineWidth: 2) }
      }
      .disabled(viewModel.isProcessing || viewModel.isCapturing)

      Spacer().frame(width: 72)
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
  @Query(sort: \Student.name) private var students: [Student]
  @AppStorage("debugMode") private var debugMode = false
  @State private var flaggedOnly = false

  private var visibleQuestions: [OMRQuestionResult] {
    let sorted = result.questions.sorted { $0.questionNumber < $1.questionNumber }
    guard flaggedOnly else { return sorted }
    return sorted.filter { $0.status != .selected || $0.confidence < 0.72 }
  }

  private var rosterCandidates: [Student] {
    guard let classroomID = exam?.classroom?.id else { return students }
    let classroomStudents = students.filter { $0.classroom?.id == classroomID }
    return classroomStudents.isEmpty ? students : classroomStudents
  }

  private var matchedStudent: Student? {
    if let id = result.studentID {
      let key = canonicalStudentID(id)
      if !key.isEmpty, let exact = rosterCandidates.first(where: { canonicalStudentID($0.studentID) == key }) {
        return exact
      }
    }

    // If the bubble ID is unreadable, use the OCR text only to match against a
    // student who already exists in the roster. We never create a student from OCR
    // and we require a high similarity so a random instruction line cannot steal a mark.
    var best: (student: Student, score: Double)?
    for student in rosterCandidates {
      let score = result.recognizedTextLines.map { nameSimilarity(student.name, $0) }.max() ?? 0
      if score >= 0.78, best == nil || score > best!.score { best = (student, score) }
    }
    return best?.student
  }

  private var displayScore: String? {
    guard exam?.answerKey != nil else { return nil }
    let maximum = exam?.maximumScore ?? Double(max(result.questions.count, 1))
    return "\(result.earnedScore.formatted(.number.precision(.fractionLength(0...2)))) / \(maximum.formatted(.number.precision(.fractionLength(0...2))))"
  }

  var body: some View {
    NavigationStack {
      List {
        if let data = result.alignedImageData, let image = UIImage(data: data) {
          Section("Aligned sheet") {
            ScanDebugPreview(
              image: image,
              debug: debugMode ? result.debug : nil,
              template: ScannerViewModel.candidateTemplates(for: exam).first(where: {
                $0.profileName == result.debug?.templateProfileName
              }) ?? ScannerViewModel.preparedTemplate(for: exam)
            )
            .frame(minHeight: 260)
          }
        }

        Section("Detection") {
          LabeledContent("Student ID", value: result.studentID ?? "Needs review")
          if let matchedStudent {
            LabeledContent("Student", value: matchedStudent.name)
          } else if result.studentID != nil || !result.recognizedTextLines.isEmpty {
            LabeledContent("Student", value: "No roster match")
          }
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
          if let displayScore {
            LabeledContent("Score", value: displayScore)
          }
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
            if let profile = debug.templateProfileName {
              LabeledContent("OMR profile", value: profile)
            }
            if let method = debug.registrationMethod {
              LabeledContent("Registration", value: method)
            }
            if let count = debug.matchedMarkerCount {
              LabeledContent("Matched markers", value: "\(count)")
            }
            if let score = debug.pageCandidateScore {
              LabeledContent(
                "Page candidate score",
                value: score.formatted(.number.precision(.fractionLength(3))))
            }
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
          Button(matchedStudent.map { "Save to \($0.name)" } ?? "Save Result") { saveResult() }
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
    let student = matchedStudent
    var savedResult = result
    if let student { savedResult.studentID = student.studentID }

    // One student should have one current mark per exam. A rescan replaces the
    // previous attempt instead of silently creating duplicate grades.
    if let exam {
      let idKey = canonicalStudentID(savedResult.studentID ?? "")
      let duplicates = exam.results.filter { existing in
        if let student, existing.student?.id == student.id { return true }
        return !idKey.isEmpty && canonicalStudentID(existing.studentID) == idKey
      }
      for existing in duplicates {
        exam.results.removeAll { $0.id == existing.id }
        context.delete(existing)
      }
    }

    let model = ExamResult(
      omrResult: savedResult,
      exam: exam,
      student: student,
      maximumScore: exam?.maximumScore)
    if let exam { exam.results.append(model) }
    context.insert(model)
    do {
      try context.save()
      dismiss()
    } catch {
      // Keep the sheet open if persistence fails so the teacher can retry instead
      // of losing the scanned mark.
      assertionFailure("Could not save scan result: \(error)")
    }
  }

  private func canonicalStudentID(_ value: String) -> String {
    value.compactMap { $0.wholeNumberValue }.map { String($0) }.joined()
  }

  private func normalizedName(_ value: String) -> String {
    let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    let cleaned = folded.map { character -> Character in
      (character.isLetter || character.isNumber || character.isWhitespace) ? character : " "
    }
    return String(cleaned).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
  }

  private func nameSimilarity(_ rosterName: String, _ ocrLine: String) -> Double {
    let name = normalizedName(rosterName)
    let line = normalizedName(ocrLine)
    guard name.count >= 3, line.count >= 3 else { return 0 }
    if line == name || line.contains(name) { return 1 }

    let nameTokens = Set(name.split(separator: " ").map(String.init))
    let lineTokens = Set(line.split(separator: " ").map(String.init))
    guard !nameTokens.isEmpty, !lineTokens.isEmpty else { return 0 }
    let intersection = Double(nameTokens.intersection(lineTokens).count)
    let union = Double(nameTokens.union(lineTokens).count)
    let tokenScore = union > 0 ? intersection / union : 0

    // Full two-token names should not match on a single common first name alone.
    let coverage = intersection / Double(nameTokens.count)
    return tokenScore * 0.45 + coverage * 0.55
  }
}

private struct ScanDebugPreview: View {
  let image: UIImage
  let debug: OMRDebugSnapshot?
  let template: TemplateDefinition

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
    .aspectRatio(CGFloat(imageAspectRatio), contentMode: .fit)
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

/// Entry point used by the Home button and Scan tab. Quick Scan automatically uses
/// the most recent exam that has an answer key, so pressing Save can immediately
/// attach a real mark to the detected student. The explicit ScannerView(exam:) path
/// used from an Exam detail page continues to use that exact exam.
struct QuickScanHostView: View {
  @Query(sort: \Exam.date, order: .reverse) private var exams: [Exam]

  private var activeExam: Exam? {
    exams.first(where: { exam in
      guard let key = exam.answerKey else { return false }
      return !key.entries.isEmpty
    }) ?? exams.first
  }

  var body: some View {
    ScannerView(exam: activeExam)
  }
}
