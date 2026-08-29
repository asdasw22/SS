import CoreGraphics
import Foundation
import ImageIO

private struct BubbleProbe: Sendable {
  let signal: Double
  let darkness: Double
  let confidence: Double
  let transformedRect: NormalizedRect
}

private struct PreparedPageCandidate: Sendable {
  let document: DetectedDocument
  let normalized: CGImage
  let gray: GrayImage
  let quality: ImageQualityReport
  let markers: [DetectedMarker]
  let alignment: TemplateAlignmentReport
  let score: Double
  let registrationWarning: String?
}

enum OMRProcessorError: LocalizedError {
  case lowQuality(String)
  case noMarkers
  case templateMismatch(String)
  case invalidTemplate(String)

  var errorDescription: String? {
    switch self {
    case .lowQuality(let message): return message
    case .noMarkers:
      return
        "Registration marks do not match this answer-sheet template. Do not grade this scan; retake the full sheet."
    case .templateMismatch(let message): return message
    case .invalidTemplate(let message): return message
    }
  }
}

struct OMRProcessor: Sendable {
  let documentDetector = DocumentDetectionService()
  let preprocessor = ImagePreprocessor()
  let markerDetector = MarkerDetectionService()
  let qualityAnalyzer = ImageQualityAnalyzer()
  let alignmentService = TemplateAlignmentService()
  let calibrator = ThresholdCalibrator()
  let classifier = BubbleClassifier()
  let idDetector = StudentIDDetector()

  func process(
    imageData: Data,
    template: TemplateDefinition,
    answerKey: [Int: AnswerChoice],
    progress: @escaping @Sendable @MainActor (OMRProcessingStage) -> Void
  ) async throws -> OMRProcessingResult {
    let templateIssues = template.validationIssues
    guard templateIssues.isEmpty else {
      throw OMRProcessorError.invalidTemplate(
        "Invalid OMR template: \(templateIssues.joined(separator: "; "))")
    }

    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
      let rawImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw OMRProcessorError.lowQuality("The selected image could not be decoded.")
    }

    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let orientationRaw = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
    let orientation = CGImagePropertyOrientation(rawValue: orientationRaw) ?? .up
    guard let image = preprocessor.orientedImage(from: rawImage, orientation: orientation) else {
      throw OMRProcessorError.lowQuality("The image orientation could not be normalized.")
    }

    await progress(.detectingPaper)
    let page = try prepareBestPage(image: image, template: template)
    let document = page.document
    let normalized = page.normalized
    let gray = page.gray
    let quality = page.quality
    let markers = page.markers
    let alignment = page.alignment

    await progress(.checkingQuality)
    await progress(.aligning)

    let studentRegion = template.studentID.map { alignment.transform.apply($0.region) }
    try validateZoneSeparation(
      template: template,
      transform: alignment.transform,
      studentRegion: studentRegion)

    // Calibrate question bubbles and Student ID bubbles independently. Their printed
    // glyphs have different ink density, so mixing both populations shifts the mark
    // threshold and was a major source of false answers in earlier revisions.
    var questionSamples: [Double] = []
    let expectedQuestionBubbleCount = template.questions.reduce(0) { $0 + $1.bubbles.count }
    for question in template.questions {
      for bubble in question.bubbles {
        if let probe = probe(
          rect: bubble.rect,
          gray: gray,
          transform: alignment.transform,
          forbiddenRegion: studentRegion)
        {
          questionSamples.append(probe.signal)
        }
      }
    }
    guard questionSamples.count >= max(8, Int(Double(expectedQuestionBubbleCount) * 0.88)) else {
      throw OMRProcessorError.templateMismatch(
        "Too many question bubbles fell outside their expected zones. Check the selected template and retake the sheet."
      )
    }

    let averageChoices =
      Double(expectedQuestionBubbleCount) / Double(max(template.questions.count, 1))
    let expectedQuestionMarkedFraction = 1.0 / max(averageChoices, 2.0)
    let questionProfile = calibrator.calibratedProfile(
      samples: questionSamples,
      base: template.calibration,
      expectedMarkedFraction: expectedQuestionMarkedFraction)

    var idProfile = template.calibration
    var idSamples: [Double] = []
    if let definition = template.studentID {
      idSamples = idDetector.signalSamples(
        definition: definition,
        in: normalized,
        transform: alignment.transform)
      if !idSamples.isEmpty {
        idProfile = calibrator.calibratedProfile(
          samples: idSamples,
          base: template.calibration,
          expectedMarkedFraction: 0.10)
      }
    }

    await progress(.readingStudentID)
    var studentID: String?
    var idConfidence = 1.0
    var warnings: [String] = page.registrationWarning.map { [$0] } ?? []
    if let definition = template.studentID {
      let detected = idDetector.detect(
        definition: definition,
        in: normalized,
        profile: idProfile,
        transform: alignment.transform)
      studentID = detected.value
      idConfidence = detected.confidence
      if let warning = detected.warning { warnings.append(warning) }
    }

    await progress(.readingAnswers)
    var questions: [OMRQuestionResult] = []
    var debugBubbles: [OMRDebugBubble] = []
    questions.reserveCapacity(template.questions.count)

    for definition in template.questions.sorted(by: { $0.number < $1.number }) {
      let canonicalBubbles = definition.bubbles.sorted {
        if $0.choice.rank == $1.choice.rank { return $0.rect.center.x < $1.rect.center.x }
        return $0.choice.rank < $1.choice.rank
      }

      var measurements: [BubbleMeasurement] = []
      var invalidBubbleCount = 0
      measurements.reserveCapacity(canonicalBubbles.count)
      for bubble in canonicalBubbles {
        guard
          let value = probe(
            rect: bubble.rect,
            gray: gray,
            transform: alignment.transform,
            forbiddenRegion: studentRegion)
        else {
          invalidBubbleCount += 1
          measurements.append(
            BubbleMeasurement(
              choice: bubble.choice,
              fillRatio: 0,
              darkness: 0,
              confidence: 0))
          continue
        }
        measurements.append(
          BubbleMeasurement(
            choice: bubble.choice,
            fillRatio: value.signal,
            darkness: value.darkness,
            confidence: value.confidence))
        debugBubbles.append(
          OMRDebugBubble(
            questionNumber: definition.number,
            choice: bubble.choice,
            rect: value.transformedRect,
            signal: value.signal,
            confidence: value.confidence))
      }

      if invalidBubbleCount > 0 {
        questions.append(
          OMRQuestionResult(
            questionNumber: definition.number,
            selectedChoices: [],
            correctChoice: answerKey[definition.number],
            status: .invalidRegion,
            confidence: 0,
            measurements: measurements,
            weight: definition.weight))
      } else {
        let classification = classifier.classify(
          measurements: measurements,
          profile: questionProfile)
        questions.append(
          OMRQuestionResult(
            questionNumber: definition.number,
            selectedChoices: classification.choices,
            correctChoice: answerKey[definition.number],
            status: classification.status,
            confidence: classification.confidence,
            measurements: measurements,
            weight: definition.weight))
      }
    }

    let invalidCount = questions.filter { $0.status == .invalidRegion }.count
    let invalidRatio = Double(invalidCount) / Double(max(questions.count, 1))
    guard invalidRatio <= 0.10 else {
      throw OMRProcessorError.templateMismatch(
        "The question area does not line up with this sheet. Grading was stopped to avoid assigning the Student ID grid as answers."
      )
    }

    // A scan where nearly every row is ambiguous is more likely a layout mismatch
    // than a class of students filling every row incorrectly.
    let ambiguousCount = questions.filter {
      $0.status == .invalidRegion || $0.status == .uncertain || $0.status == .weak
        || $0.status == .multiple
    }.count
    let ambiguousRatio = Double(ambiguousCount) / Double(max(questions.count, 1))
    if template.strictRegistration == true && questions.count >= 5 && ambiguousRatio > 0.45 {
      throw OMRProcessorError.templateMismatch(
        "This scan does not line up with the full answer sheet. Too many rows look like multiple or empty answers. Make sure the entire page is visible; do not crop around the Student ID table."
      )
    } else if questions.count >= 5 && ambiguousRatio > 0.65 {
      warnings.append(
        "Many rows are ambiguous. Verify that this is the configured answer-sheet layout before saving."
      )
    }

    await progress(.calculating)
    var needsReview =
      questions.contains {
        $0.status == .weak || $0.status == .uncertain || $0.status == .multiple
          || $0.status == .invalidRegion
      } || (template.studentID != nil && (studentID == nil || idConfidence < 0.66))

    if !quality.isAcceptable {
      needsReview = true
      warnings.append(
        "Image quality is usable but not ideal; review flagged answers before saving.")
    }
    if alignment.reprojectionError > template.calibration.markerReprojectionTolerance {
      needsReview = true
      warnings.append(
        "The page required extra registration correction because of camera angle or paper distortion."
      )
    }
    if document.usedFullFrameFallback && markers.count < 3 {
      needsReview = true
      warnings.append(
        "The full image frame was used as the page because no stronger page candidate was found. Review flagged fields before saving."
      )
    }
    if answerKey.isEmpty {
      warnings.append(
        "No answer key is stored for this exam. Answers were detected but cannot be scored yet.")
    }

    let qualityComponent = quality.score
    let alignmentComponent = template.markers.isEmpty ? 1 : alignment.confidence
    let regionComponent = max(0, 1 - invalidRatio * 2.0)
    let paperConfidence = min(
      1,
      max(
        0,
        Double(document.confidence) * 0.28
          + alignmentComponent * 0.38
          + qualityComponent * 0.22
          + regionComponent * 0.12
      ))
    if paperConfidence < 0.70 {
      needsReview = true
      warnings.append("Overall scan confidence is below the safe auto-grade threshold.")
    }

    let markerDebug = markers.enumerated().map { index, marker in
      OMRDebugMarker(
        id: index,
        expected: NormalizedPoint(
          x: Double(marker.expectedCenter.x), y: Double(marker.expectedCenter.y)),
        detected: NormalizedPoint(x: Double(marker.center.x), y: Double(marker.center.y)),
        confidence: marker.confidence)
    }
    let idDebug =
      template.studentID.map {
        idDetector.debugCells(definition: $0, in: normalized, transform: alignment.transform)
      } ?? []
    let debug = OMRDebugSnapshot(
      bubbles: debugBubbles,
      markers: markerDebug,
      idCells: idDebug,
      alignmentScaleX: alignment.scaleX,
      alignmentScaleY: alignment.scaleY,
      alignmentRotationDegrees: alignment.rotationDegrees,
      alignmentShear: alignment.shear,
      maximumAlignmentDrift: alignment.maximumDrift,
      questionDecisionBoundary: questionProfile.decisionBoundary,
      studentIDDecisionBoundary: template.studentID == nil ? nil : idProfile.decisionBoundary,
      registrationMethod: document.source.rawValue,
      matchedMarkerCount: markers.count,
      pageCandidateScore: page.score)

    await progress(.complete)
    let alignedData = ImageRenderer.jpegData(from: normalized)
    return OMRProcessingResult(
      studentID: studentID,
      questions: questions,
      paperConfidence: paperConfidence,
      needsReview: needsReview,
      warnings: Array(Set(warnings)).sorted(),
      alignedImageData: alignedData,
      studentIDConfidence: template.studentID == nil ? nil : idConfidence,
      debug: debug)
  }

  private func prepareBestPage(
    image: CGImage,
    template: TemplateDefinition
  ) throws -> PreparedPageCandidate {
    let documents = try documentDetector.candidates(
      in: image,
      expectedAspectRatio: template.pageAspectRatio,
      template: template)
    let imageSize = CGSize(width: image.width, height: image.height)

    var validated: [PreparedPageCandidate] = []
    var fallbacks: [PreparedPageCandidate] = []
    var sawRectifiedCandidate = false
    var sawUsableQuality = false

    for document in documents {
      let corners = document.normalizedCorners.map {
        CGPoint(x: $0.x * imageSize.width, y: $0.y * imageSize.height)
      }
      guard
        let corrected = preprocessor.correctedImage(
          from: image,
          corners: corners,
          targetAspectRatio: template.pageAspectRatio,
          longEdge: 1320),
        let normalized = preprocessor.normalizedImage(from: corrected),
        let gray = GrayImage(cgImage: normalized)
      else { continue }

      sawRectifiedCandidate = true
      let quality = qualityAnalyzer.analyze(normalized)
      guard quality.isUsable else { continue }
      sawUsableQuality = true

      let markers = markerDetector.detect(
        in: normalized,
        expected: template.markers,
        profile: template.calibration)
      let rawAlignment = alignmentService.validate(markers: markers, template: template)

      let desiredMarkerCount = max(4, min(template.markers.count, 6))
      let markerEvidence = min(1, Double(markers.count) / Double(desiredMarkerCount))
      let sourceBonus: Double = document.source == .fiducialMarkers ? 0.08 : 0
      let aspectEvidence = max(0, min(1, document.aspectScore))

      var effectiveAlignment = rawAlignment
      var warning: String?
      var strongRegistration = false

      if rawAlignment.isCompatible && rawAlignment.geometryIsSane {
        strongRegistration = true
      } else if markers.count >= 3,
        rawAlignment.geometryIsSane,
        rawAlignment.confidence >= 0.34
      {
        // Three or more markers after page rectification are enough for a small
        // affine correction. Bubble-layout validation still runs before a result
        // can be returned.
        strongRegistration = true
        warning = "Registration used a reduced marker set. Review only fields that are flagged."
      } else if document.source == .fiducialMarkers {
        // The raw page itself was already recovered from at least four distributed
        // markers. If the second marker pass is weakened by blur/moire, the page is
        // nevertheless in canonical geometry, so use identity instead of failing.
        effectiveAlignment = alignmentService.identityFallback(
          matchedMarkers: markers.count,
          confidence: max(0.52, Double(document.confidence)))
        strongRegistration = true
        warning = "The page was registered directly from the printed black squares."
      } else {
        let rectangleIsCredible =
          document.source == .visionPage
          && document.area >= 0.095
          && document.aspectScore >= 0.46
          && document.confidence >= 0.38
        let fullFrameIsCredible =
          document.source == .fullFrame
          && document.aspectScore >= 0.90
          && document.confidence >= 0.80
        if rectangleIsCredible || fullFrameIsCredible {
          // Do not abort just because page markers are faint. This mirrors robust
          // OMR pipelines that allow page-edge cropping to be skipped and let the
          // configured bubble layout validate the crop. Any bad crop will later fail
          // zone/ambiguity checks instead of producing a confident wrong grade.
          effectiveAlignment = alignmentService.identityFallback(
            matchedMarkers: markers.count,
            confidence: max(0.35, Double(document.confidence) * 0.70))
          warning =
            "Not all registration squares were readable; the detected page boundary and bubble layout were used as fallback. Review flagged fields."
        } else {
          continue
        }
      }

      let alignmentEvidence = strongRegistration
        ? max(0.56, rawAlignment.confidence)
        : max(0.28, effectiveAlignment.confidence)
      let score = min(
        1.25,
        Double(document.confidence) * 0.25
          + quality.score * 0.17
          + markerEvidence * 0.25
          + alignmentEvidence * 0.23
          + aspectEvidence * 0.10
          + sourceBonus)
      let prepared = PreparedPageCandidate(
        document: document,
        normalized: normalized,
        gray: gray,
        quality: quality,
        markers: markers,
        alignment: effectiveAlignment,
        score: score,
        registrationWarning: warning)

      if strongRegistration {
        validated.append(prepared)
        if score >= 0.86 && markers.count >= 5 { break }
      } else {
        fallbacks.append(prepared)
      }
    }

    if let best = validated.max(by: { $0.score < $1.score }) { return best }
    if let best = fallbacks.max(by: { $0.score < $1.score }) { return best }

    if sawRectifiedCandidate && !sawUsableQuality {
      throw OMRProcessorError.lowQuality(
        "A page was found, but the image is too blurred or unevenly exposed. Hold the phone steady, improve lighting, or import the original image from Photos.")
    }
    throw OMRProcessorError.noMarkers
  }

  private func validateZoneSeparation(
    template: TemplateDefinition,
    transform: AlignmentTransform,
    studentRegion: CGRect?
  ) throws {
    guard let studentRegion else { return }
    for question in template.questions {
      guard let bounds = question.bounds else {
        throw OMRProcessorError.invalidTemplate("Question \(question.number) has no bubbles.")
      }
      let transformed = transform.apply(bounds)
      guard !transformed.isNull,
        transformed.minX >= -0.01,
        transformed.minY >= -0.01,
        transformed.maxX <= 1.01,
        transformed.maxY <= 1.01
      else {
        throw OMRProcessorError.templateMismatch(
          "Question \(question.number) moved outside the aligned page.")
      }
      let overlap = transformed.intersection(studentRegion)
      if !overlap.isNull {
        let ratio =
          Double(overlap.width * overlap.height)
          / max(Double(transformed.width * transformed.height), 0.000_001)
        if ratio > 0.015 {
          throw OMRProcessorError.templateMismatch(
            "Question and Student ID zones overlap after alignment. Grading was stopped.")
        }
      }
    }
  }

  private func probe(
    rect: NormalizedRect,
    gray: GrayImage,
    transform: AlignmentTransform,
    forbiddenRegion: CGRect?
  ) -> BubbleProbe? {
    let transformed = transform.apply(rect)
    guard !transformed.isNull,
      transformed.width > 0.002,
      transformed.height > 0.002,
      transformed.minX >= 0,
      transformed.maxX <= 1,
      transformed.minY >= 0,
      transformed.maxY <= 1
    else { return nil }

    if let forbiddenRegion,
      !forbiddenRegion.isNull,
      transformed.intersects(forbiddenRegion)
    {
      let intersection = transformed.intersection(forbiddenRegion)
      let area = max(transformed.width * transformed.height, 0.000_001)
      let ratio = intersection.isNull ? 0 : (intersection.width * intersection.height) / area
      if ratio > 0.02 { return nil }
    }

    let size = CGSize(width: gray.width, height: gray.height)
    let pixelRect = CGRect(
      x: transformed.minX * size.width,
      y: transformed.minY * size.height,
      width: transformed.width * size.width,
      height: transformed.height * size.height)
    guard pixelRect.width >= 6, pixelRect.height >= 6 else { return nil }

    let stats = gray.bubbleStatistics(in: pixelRect)
    let signal = min(1, max(0, stats.fillRatio * 0.76 + stats.darkness * 0.24))
    let confidence = min(
      1,
      max(
        0.08,
        0.34
          + stats.contrast * 0.46
          + abs(stats.fillRatio - 0.5) * 0.16))
    return BubbleProbe(
      signal: signal,
      darkness: stats.darkness,
      confidence: confidence,
      transformedRect: NormalizedRect(cgRect: transformed))
  }
}
