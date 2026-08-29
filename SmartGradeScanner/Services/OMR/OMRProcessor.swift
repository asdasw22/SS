import CoreGraphics
import Foundation
import ImageIO

private struct BubbleProbe: Sendable {
  let signal: Double
  let darkness: Double
  let confidence: Double
  let transformedRect: NormalizedRect
}

private struct RowShiftCandidate: Sendable {
  let values: [BubbleProbe?]
  let score: Double
  let strongestIndex: Int
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
  let sourceRotationDegrees: Int
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
  let ocr = OCRService()

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
    let page = try prepareBestOrientedPage(image: image, template: template)
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

    // Run one fast OCR pass on the canonical page. Besides being a fallback for an
    // unclear bubble ID, these lines let the review screen match the printed student
    // name to the local roster. Keeping one shared pass avoids doing OCR twice.
    let alignedDataForOCR = ImageRenderer.pngData(from: normalized)
    let recognizedTextLines: [String]
    if let alignedDataForOCR {
      recognizedTextLines = await ocr.recognizeText(in: alignedDataForOCR)
    } else {
      recognizedTextLines = []
    }

    if let definition = template.studentID {
      let detected = idDetector.detect(
        definition: definition,
        in: normalized,
        profile: idProfile,
        transform: alignment.transform)
      studentID = detected.value
      idConfidence = detected.confidence
      if let warning = detected.warning { warnings.append(warning) }

      // Some legacy/printed sheets show the complete numeric ID as text next to an
      // incomplete or damaged bubble grid. OMR remains primary, but Vision OCR is a
      // safe secondary verifier when the grid cannot produce a trustworthy value.
      if studentID == nil || idConfidence < 0.62 {
        if let ocrID = bestPrintedStudentID(
          in: recognizedTextLines, preferredPrefix: definition.prefix)
        {
          studentID = ocrID
          idConfidence = max(idConfidence, 0.78)
          warnings.append(
            "Student ID was recovered from the printed numeric text because the bubble grid was incomplete or ambiguous.")
        }
      }
    }

    await progress(.readingAnswers)
    var questions: [OMRQuestionResult] = []
    var debugBubbles: [OMRDebugBubble] = []
    questions.reserveCapacity(template.questions.count)

    for definition in template.questions.sorted(by: { $0.number < $1.number }) {
      // Built-in university sheets use a strict spatial answer model: the left-most
      // bubble is A, then B, C, D, E.  We intentionally do not OCR the printed
      // letters to decide the answer.  This prevents a distorted/blurred A/B glyph
      // from changing the semantic choice; position is the source of truth.
      let spatiallyOrdered = definition.bubbles.sorted { $0.rect.center.x < $1.rect.center.x }
      let spatialChoices = Array(AnswerChoice.allCases.prefix(spatiallyOrdered.count))
      let canonicalBubbles: [(coordinate: BubbleCoordinate, choice: AnswerChoice)]
      if template.isBuiltInAutoProfile {
        canonicalBubbles = zip(spatiallyOrdered, spatialChoices).map { ($0.0, $0.1) }
      } else {
        canonicalBubbles = definition.bubbles
          .sorted { $0.choice.rank < $1.choice.rank }
          .map { ($0, $0.choice) }
      }

      let rowResult = measureRow(
        canonicalBubbles: canonicalBubbles,
        questionNumber: definition.number,
        gray: gray,
        transform: alignment.transform,
        forbiddenRegion: studentRegion)
      let measurements = rowResult.measurements
      let invalidBubbleCount = rowResult.invalidCount
      debugBubbles.append(contentsOf: rowResult.debug)
      if rowResult.usedLocalRealignment {
        warnings.append(
          "Some rows needed local registration correction because of camera angle or a curved page; review flagged answers before saving."
        )
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
            weight: definition.weight,
            detectedBounds: rowResult.detectedBounds))
      } else {
        let classification = classifier.classify(
          measurements: measurements,
          profile: questionProfile)
        let finalStatus: ResponseStatus = rowResult.usedLocalRealignment
          && classification.status == .selected ? .weak : classification.status
        let finalConfidence = rowResult.usedLocalRealignment
          ? min(0.71, classification.confidence) : classification.confidence
        questions.append(
          OMRQuestionResult(
            questionNumber: definition.number,
            selectedChoices: classification.choices,
            correctChoice: answerKey[definition.number],
            status: finalStatus,
            confidence: finalConfidence,
            measurements: measurements,
            weight: definition.weight,
            detectedBounds: rowResult.detectedBounds))
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
    let meanQuestionConfidence = questions.map(\.confidence).reduce(0, +)
      / Double(max(questions.count, 1))
    let decisionComponent = max(
      0,
      min(1, meanQuestionConfidence * (1 - ambiguousRatio * 0.70)))
    let paperConfidence = min(
      1,
      max(
        0,
        Double(document.confidence) * 0.22
          + alignmentComponent * 0.30
          + qualityComponent * 0.16
          + regionComponent * 0.10
          + decisionComponent * 0.22
      ))
    if paperConfidence < 0.76 {
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
      pageCandidateScore: page.score,
      templateProfileName: template.profileName,
      alignmentConfidence: alignment.confidence,
      markerCoverage: alignment.coverage,
      reprojectionError: alignment.reprojectionError.isFinite
        ? alignment.reprojectionError : nil,
      imageQualityScore: quality.score,
      invalidQuestionRatio: invalidRatio,
      ambiguousQuestionRatio: ambiguousRatio,
      sourceRotationDegrees: page.sourceRotationDegrees)

    await progress(.complete)
    let alignedData = alignedDataForOCR ?? ImageRenderer.pngData(from: normalized)
    return OMRProcessingResult(
      studentID: studentID,
      questions: questions,
      paperConfidence: paperConfidence,
      needsReview: needsReview,
      warnings: Array(Set(warnings)).sorted(),
      alignedImageData: alignedData,
      recognizedTextLines: recognizedTextLines,
      studentIDConfidence: template.studentID == nil ? nil : idConfidence,
      debug: debug)
  }

  /// Tries the EXIF-normalized pixels first, then right-angle rotations only when
  /// the primary view cannot produce strong registration. Some messaging apps and
  /// image editors strip EXIF orientation; rejecting those sheets is safer than
  /// treating their reciprocal aspect ratio as a different physical template.
  private func prepareBestOrientedPage(
    image: CGImage,
    template: TemplateDefinition
  ) throws -> PreparedPageCandidate {
    var candidates: [PreparedPageCandidate] = []
    var firstError: Error?

    do {
      let primary = try prepareBestPage(
        image: image,
        template: template,
        sourceRotationDegrees: 0)
      candidates.append(primary)
      let requiredMarkers = min(
        template.markers.count,
        max(template.calibration.minimumMarkerCount, 3))
      let registrationIsStrong = template.markers.isEmpty
        || primary.markers.count >= requiredMarkers
        || (primary.document.source == .fiducialMarkers && primary.score >= 0.78)
      if registrationIsStrong, primary.score >= 0.82 { return primary }
    } catch {
      firstError = error
    }

    for degrees in [90, 270, 180] {
      guard let rotated = preprocessor.rotatedImage(from: image, degreesClockwise: degrees)
      else { continue }
      if let candidate = try? prepareBestPage(
        image: rotated,
        template: template,
        sourceRotationDegrees: degrees)
      {
        candidates.append(candidate)
      }
    }

    guard let best = candidates.max(by: { $0.score < $1.score }) else {
      throw firstError ?? OMRProcessorError.noMarkers
    }
    guard best.sourceRotationDegrees != 0 else { return best }
    let rotationWarning =
      "The image had missing or incorrect orientation metadata and was rotated automatically."
    let combinedWarning = [best.registrationWarning, rotationWarning]
      .compactMap { $0 }
      .joined(separator: " ")
    return PreparedPageCandidate(
      document: best.document,
      normalized: best.normalized,
      gray: best.gray,
      quality: best.quality,
      markers: best.markers,
      alignment: best.alignment,
      score: best.score,
      registrationWarning: combinedWarning,
      sourceRotationDegrees: best.sourceRotationDegrees)
  }

  private func prepareBestPage(
    image: CGImage,
    template: TemplateDefinition,
    sourceRotationDegrees: Int = 0
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
      // An imported/scanned image that already matches the page aspect ratio must
      // never be pushed through perspective correction. Doing so can turn a clean
      // portrait sheet into a trapezoid when a false rectangle/marker hypothesis
      // wins. Full-frame candidates are only uniformly resized; camera candidates
      // still receive real perspective correction.
      let corrected: CGImage?
      if document.source == .fullFrame {
        corrected = preprocessor.resizedImage(from: image, longEdge: 1320)
      } else {
        corrected = preprocessor.correctedImage(
          from: image,
          corners: corners,
          targetAspectRatio: template.pageAspectRatio,
          longEdge: 1320)
      }
      guard
        let corrected,
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
        profile: template.calibration,
        ignoredAreas: template.ignoredAreas)
      let rawAlignment = alignmentService.validate(markers: markers, template: template)

      let desiredMarkerCount = max(4, min(template.markers.count, 6))
      let markerEvidence = min(1, Double(markers.count) / Double(desiredMarkerCount))
      let sourceBonus: Double
      switch document.source {
      case .fiducialMarkers: sourceBonus = 0.06
      case .fullFrame: sourceBonus = 0.10
      case .visionPage: sourceBonus = 0
      }
      let aspectEvidence = max(0, min(1, document.aspectScore))

      var effectiveAlignment = rawAlignment
      var warning: String?
      var strongRegistration = false

      if rawAlignment.isCompatible && rawAlignment.geometryIsSane {
        strongRegistration = true
      } else if document.source == .fiducialMarkers {
        // Marker-first page recovery already solved a projective page transform from
        // distributed black squares.  A weak second pass can therefore use identity.
        effectiveAlignment = alignmentService.identityFallback(
          matchedMarkers: markers.count,
          confidence: max(0.58, Double(document.confidence)))
        strongRegistration = true
        warning = "The page was registered directly from the printed black squares."
      } else if markers.count >= 4,
        rawAlignment.geometryIsSane,
        rawAlignment.confidence >= 0.44,
        rawAlignment.coverage >= 0.18
      {
        // Reduced-marker fallback is accepted only when the markers are distributed
        // across the page.  This blocks a monitor/window/Student-ID rectangle from
        // masquerading as another built-in sheet profile.
        strongRegistration = true
        warning = "Registration used a reduced but spatially distributed marker set."
      } else if template.strictRegistration == true || template.isBuiltInAutoProfile {
        // For built-in sheets, a plausible rectangle is NOT enough.  Returning no
        // result is safer than stretching the wrong rectangle to a template and
        // inventing answers.
        continue
      } else {
        let rectangleIsCredible =
          document.source == .visionPage
          && document.area >= 0.095
          && document.aspectScore >= 0.58
          && document.confidence >= 0.44
        let fullFrameIsCredible =
          document.source == .fullFrame
          && document.aspectScore >= 0.94
          && document.confidence >= 0.82
        if rectangleIsCredible || fullFrameIsCredible {
          effectiveAlignment = alignmentService.identityFallback(
            matchedMarkers: markers.count,
            confidence: max(0.35, Double(document.confidence) * 0.70))
          warning =
            "Page-edge fallback was used for this custom template. Review flagged fields."
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
        registrationWarning: warning,
        sourceRotationDegrees: sourceRotationDegrees)

      if strongRegistration {
        validated.append(prepared)
      } else {
        fallbacks.append(prepared)
      }
    }

    // Prefer an already-flat full-page import whenever its printed markers agree
    // with the template. This is both more accurate and visually lossless: there is
    // no reason to re-project a scanner/Photos image that is already canonical.
    if let flatImport = validated
      .filter({
        $0.document.source == .fullFrame
          && $0.document.aspectScore >= 0.96
          && $0.markers.count >= 4
          && $0.alignment.confidence >= 0.52
          && $0.alignment.maximumDrift <= 0.075
      })
      .max(by: { $0.score < $1.score })
    {
      return flatImport
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

  private func bestPrintedStudentID(in lines: [String], preferredPrefix: String) -> String? {
    let normalizedLines = lines.map { normalizedDigits($0) }
    var candidates: [String] = []
    for line in normalizedLines {
      var current = ""
      for character in line {
        if character.isNumber {
          current.append(character)
        } else if !current.isEmpty {
          if current.count >= 8 { candidates.append(current) }
          current = ""
        }
      }
      if current.count >= 8 { candidates.append(current) }
    }
    let plausible = candidates.filter {
      (8...14).contains($0.count)
        && (preferredPrefix.isEmpty || $0.hasPrefix(preferredPrefix))
    }
    guard !plausible.isEmpty else { return nil }
    return plausible.sorted { lhs, rhs in
      let lhsPrefix = !preferredPrefix.isEmpty && lhs.hasPrefix(preferredPrefix)
      let rhsPrefix = !preferredPrefix.isEmpty && rhs.hasPrefix(preferredPrefix)
      if lhsPrefix != rhsPrefix { return lhsPrefix && !rhsPrefix }
      if lhs.count != rhs.count { return lhs.count > rhs.count }
      return lhs < rhs
    }.first
  }

  private func normalizedDigits(_ text: String) -> String {
    let map: [Character: Character] = [
      "٠": "0", "١": "1", "٢": "2", "٣": "3", "٤": "4",
      "٥": "5", "٦": "6", "٧": "7", "٨": "8", "٩": "9",
      "۰": "0", "۱": "1", "۲": "2", "۳": "3", "۴": "4",
      "۵": "5", "۶": "6", "۷": "7", "۸": "8", "۹": "9",
    ]
    return String(text.map { map[$0] ?? $0 })
  }

  private struct RowMeasurement {
    let measurements: [BubbleMeasurement]
    let invalidCount: Int
    let debug: [OMRDebugBubble]
    let usedLocalRealignment: Bool
    let detectedBounds: NormalizedRect?
  }

  // Reads one question row. The homography-projected template position is tried
  // first. Real photographed sheets can retain a small amount of local drift (a
  // slightly curved page, a residual lens/perspective error that a single global
  // transform cannot fully absorb) that grows with distance from the nearest
  // registration marker. When the row's own zero-offset reading is too weak or too
  // flat to trust, a bounded local search re-probes the same five bubbles with a
  // small rigid shift and keeps the shift that produces the clearest single-cell
  // signal. This never invents an answer out of noise: a shift is only adopted when
  // it produces a materially stronger, cleaner peak than the original position, and
  // the classifier's own review thresholds still apply to whatever is returned.
  private func measureRow(
    canonicalBubbles: [(coordinate: BubbleCoordinate, choice: AnswerChoice)],
    questionNumber: Int,
    gray: GrayImage,
    transform: AlignmentTransform,
    forbiddenRegion: CGRect?
  ) -> RowMeasurement {
    func probeAll(offset: CGVector) -> (values: [BubbleProbe?], invalidCount: Int) {
      var invalidCount = 0
      let values = canonicalBubbles.map { item -> BubbleProbe? in
        guard
          let value = probe(
            rect: item.coordinate.rect,
            gray: gray,
            transform: transform,
            forbiddenRegion: forbiddenRegion,
            rowOffset: offset)
        else {
          invalidCount += 1
          return nil
        }
        return value
      }
      return (values, invalidCount)
    }

    func peakScore(_ values: [BubbleProbe?]) -> Double {
      let signals = values.compactMap { $0?.signal }
      guard signals.count >= 2 else { return 0 }
      let sorted = signals.sorted()
      let median = sorted[sorted.count / 2]
      return (sorted.last ?? 0) - median
    }

    let base = probeAll(offset: .zero)
    var bestValues = base.values
    var bestInvalidCount = base.invalidCount
    var usedLocalRealignment = false

    // Only search when nothing failed outright (an out-of-page or forbidden-zone
    // bubble means the template genuinely does not fit here, which local nudging
    // cannot and should not paper over) and the row looks weak enough to doubt.
    let baseSignals = base.values.compactMap { $0?.signal }
    let baseBest = baseSignals.max() ?? 0
    let baseScore = peakScore(base.values)
    let rowLooksWeak = baseBest < 0.55 || baseScore < 0.22
    if base.invalidCount == 0, rowLooksWeak {
      var shiftCandidates: [RowShiftCandidate] = []
      let verticalOffsets: [Double] = [-0.42, -0.28, 0.28, 0.42]
      let horizontalOffsets: [Double] = [-0.14, 0, 0.14]
      for dy in verticalOffsets {
        for dx in horizontalOffsets {
          let offset = CGVector(dx: dx, dy: dy)
          let candidate = probeAll(offset: offset)
          guard candidate.invalidCount == 0 else { continue }
          let indexedSignals = candidate.values.enumerated().compactMap { index, value in
            value.map { (index: index, signal: $0.signal) }
          }
          guard let strongest = indexedSignals.max(by: { $0.signal < $1.signal }) else { continue }
          let candidateBest = strongest.signal
          let candidateScore = peakScore(candidate.values)
          guard candidateBest >= 0.45, candidateScore > baseScore + 0.12 else { continue }
          shiftCandidates.append(
            RowShiftCandidate(
              values: candidate.values,
              score: candidateScore,
              strongestIndex: strongest.index))
        }
      }

      // A single offset can accidentally land on a printed glyph or compression
      // artifact. Adopt a local correction only when at least two nearby probes
      // independently agree on the same physical bubble.
      let consensusGroups = Dictionary(grouping: shiftCandidates, by: \.strongestIndex)
        .values
        .filter { $0.count >= 2 }
      if let consensus = consensusGroups.max(by: {
        ($0.map(\.score).max() ?? 0) < ($1.map(\.score).max() ?? 0)
      }),
        let winner = consensus.max(by: { $0.score < $1.score })
      {
        bestValues = winner.values
        bestInvalidCount = 0
        usedLocalRealignment = true
      }
    }

    var measurements: [BubbleMeasurement] = []
    var debug: [OMRDebugBubble] = []
    measurements.reserveCapacity(canonicalBubbles.count)
    for (item, value) in zip(canonicalBubbles, bestValues) {
      guard let value else {
        measurements.append(
          BubbleMeasurement(choice: item.choice, fillRatio: 0, darkness: 0, confidence: 0))
        continue
      }
      measurements.append(
        BubbleMeasurement(
          choice: item.choice,
          fillRatio: value.signal,
          darkness: value.darkness,
          confidence: value.confidence))
      debug.append(
        OMRDebugBubble(
          questionNumber: questionNumber,
          choice: item.choice,
          rect: value.transformedRect,
          signal: value.signal,
          confidence: value.confidence))
    }
    let detectedBounds: NormalizedRect?
    if let first = debug.first {
      let union = debug.dropFirst().reduce(first.rect.cgRect) { $0.union($1.rect.cgRect) }
      detectedBounds = NormalizedRect(cgRect: union)
    } else {
      detectedBounds = nil
    }
    return RowMeasurement(
      measurements: measurements,
      invalidCount: bestInvalidCount,
      debug: debug,
      usedLocalRealignment: usedLocalRealignment,
      detectedBounds: detectedBounds)
  }

  private func probe(
    rect: NormalizedRect,
    gray: GrayImage,
    transform: AlignmentTransform,
    forbiddenRegion: CGRect?,
    rowOffset: CGVector = .zero
  ) -> BubbleProbe? {
    var transformed = transform.apply(rect)
    if rowOffset != .zero {
      transformed = transformed.offsetBy(
        dx: transformed.width * rowOffset.dx,
        dy: transformed.height * rowOffset.dy)
    }
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
    let basePixelRect = CGRect(
      x: transformed.minX * size.width,
      y: transformed.minY * size.height,
      width: transformed.width * size.width,
      height: transformed.height * size.height)
    guard basePixelRect.width >= 6, basePixelRect.height >= 6 else { return nil }
    let scales: [CGFloat] = [0.94, 1.00, 1.06]
    let samples = scales.map { scale in
      let candidate = CGRect(
        x: basePixelRect.midX - basePixelRect.width * scale / 2,
        y: basePixelRect.midY - basePixelRect.height * scale / 2,
        width: basePixelRect.width * scale,
        height: basePixelRect.height * scale)
      return gray.bubbleStatistics(in: candidate)
    }
    let signals = samples.map { min(1, max(0, $0.fillRatio * 0.92 + $0.darkness * 0.08)) }
      .sorted()
    let darknessValues = samples.map { $0.darkness }.sorted()
    let contrastValues = samples.map { $0.contrast }.sorted()
    guard signals.count == 3 else { return nil }
    let signal = signals[1]
    let darkness = darknessValues[1]
    let contrast = contrastValues[1]
    let scaleSpread = (signals.last ?? signal) - (signals.first ?? signal)
    let stability = max(0, 1 - scaleSpread / 0.22)
    let confidence = min(
      1,
      max(
        0.08,
        0.26
          + contrast * 0.42
          + abs(signal - 0.5) * 0.17
          + stability * 0.15))
    return BubbleProbe(
      signal: signal,
      darkness: darkness,
      confidence: confidence,
      transformedRect: NormalizedRect(cgRect: transformed))
  }
}
