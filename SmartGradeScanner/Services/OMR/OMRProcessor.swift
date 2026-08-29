import CoreGraphics
import Foundation
import ImageIO

private struct BubbleProbe: Sendable {
  let signal: Double
  let darkness: Double
  let confidence: Double
  let blobFill: Double
  let otsuFill: Double
  let coverage: Double
  let edgeReach: Double
  let occupancy: Double
  let blobCount: Double
  let multiConsistency: Double
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
    case .lowQuality(let message): return "RESCAN_REQUIRED - \(message)"
    case .noMarkers:
      return
        "TEMPLATE_ALIGNMENT_FAILED - Registration marks do not match this answer-sheet template. Do not grade this scan; retake the full sheet."
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
          forbiddenRegion: studentRegion,
          strict: template.isFixedOMRStrict)
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

    // Fixed-sheet strict mode never runs OCR: decisions are purely geometrical
    // (registration squares, fixed bubble positions and the 7-column ID grid).
    // OCR stays available only for user-created custom templates.
    let alignedData = ImageRenderer.jpegData(from: normalized)
    let recognizedTextLines: [String]
    if template.isFixedOMRStrict {
      recognizedTextLines = []
    } else if let alignedData {
      recognizedTextLines = await ocr.recognizeText(in: alignedData)
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
      // safe secondary verifier for custom templates when the grid is unclear.
      // The fixed sheet is excluded: its ID must come from its own bubble grid.
      if !template.isFixedOMRStrict, studentID == nil || idConfidence < 0.62 {
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
        forbiddenRegion: studentRegion,
        strict: template.isFixedOMRStrict)
      let measurements = rowResult.measurements
      let invalidBubbleCount = rowResult.invalidCount
      debugBubbles.append(contentsOf: rowResult.debug)

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
        let classification: (choices: [AnswerChoice], status: ResponseStatus, confidence: Double)
        if template.isFixedOMRStrict {
          // Strict fixed-sheet decisions (selected/multiple/blank/ambiguous) only;
          // never OCR, never a guessed nearest bubble.
          classification = classifier.classifyStrict(
            measurements: measurements, profile: questionProfile)
        } else {
          classification = classifier.classify(
            measurements: measurements, profile: questionProfile)
        }
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
        "Too many rows are invalid or ambiguous. Make sure the entire page is visible and matches the fixed answer sheet; do not crop around the Student ID table."
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
      pageCandidateScore: page.score,
      templateProfileName: template.profileName)

    await progress(.complete)
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

      if template.isFixedOMRStrict {
        // Fixed sheet: fail closed. Registration must come from a distributed,
        // exactly-matching marker set spanning the top and bottom of the page.
        // Identity / page-edge fallbacks are never allowed for this profile.
        guard rawAlignment.isCompatible,
          rawAlignment.geometryIsSane,
          markers.count >= 6
        else { continue }
        let topCount = markers.filter { $0.center.y < 0.5 }.count
        let bottomCount = markers.filter { $0.center.y >= 0.5 }.count
        guard topCount >= 3, bottomCount >= 2 else { continue }
      }

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
        registrationWarning: warning)

      if strongRegistration {
        validated.append(prepared)
        if score >= 0.86 && markers.count >= 5 { break }
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
    let plausible = candidates.filter { (8...14).contains($0.count) }
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
  }

  // Reads one question row at its fixed template positions ONLY. The homography
  // already registered the page from the registration squares; no local search or
  // nudging is ever applied, so a reading can never drift into a neighbouring row
  // or onto the Student-ID grid. Bubbles are probed exactly at their projected
  // A/B/C/D/E centers and nowhere else.
  private func measureRow(
    canonicalBubbles: [(coordinate: BubbleCoordinate, choice: AnswerChoice)],
    questionNumber: Int,
    gray: GrayImage,
    transform: AlignmentTransform,
    forbiddenRegion: CGRect?,
    strict: Bool
  ) -> RowMeasurement {
    var measurements: [BubbleMeasurement] = []
    var debug: [OMRDebugBubble] = []
    var invalidCount = 0
    measurements.reserveCapacity(canonicalBubbles.count)

    for item in canonicalBubbles {
      guard
        let value = probe(
          rect: item.coordinate.rect,
          gray: gray,
          transform: transform,
          forbiddenRegion: forbiddenRegion,
          strict: strict)
      else {
        invalidCount += 1
        measurements.append(
          BubbleMeasurement(choice: item.choice, fillRatio: 0, darkness: 0, confidence: 0))
        continue
      }
      measurements.append(
        BubbleMeasurement(
          choice: item.choice,
          fillRatio: value.signal,
          darkness: value.darkness,
          confidence: value.confidence,
          blobFill: value.blobFill,
          otsuFill: value.otsuFill,
          coverage: value.coverage,
          edgeReach: value.edgeReach,
          occupancy: value.occupancy,
          blobCount: value.blobCount,
          multiConsistency: value.multiConsistency))
      debug.append(
        OMRDebugBubble(
          questionNumber: questionNumber,
          choice: item.choice,
          rect: value.transformedRect,
          signal: value.signal,
          confidence: value.confidence))
    }

    return RowMeasurement(
      measurements: measurements,
      invalidCount: invalidCount,
      debug: debug)
  }

  private func probe(
    rect: NormalizedRect,
    gray: GrayImage,
    transform: AlignmentTransform,
    forbiddenRegion: CGRect?,
    strict: Bool = false
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
    let basePixelRect = CGRect(
      x: transformed.minX * size.width,
      y: transformed.minY * size.height,
      width: transformed.width * size.width,
      height: transformed.height * size.height)
    guard basePixelRect.width >= 6, basePixelRect.height >= 6 else { return nil }
    // Fixed-sheet strict mode measures only the inner disk, ignoring the printed
    // circular frame and letter. The normal path keeps the legacy full analysis.
    let evidence: BubbleEvidence
    if strict {
      evidence = gray.strictBubbleEvidence(in: basePixelRect)
    } else {
      let pixelRect = basePixelRect.insetBy(
        dx: -basePixelRect.width * 0.06,
        dy: -basePixelRect.height * 0.06)
      evidence = gray.bubbleEvidence(in: pixelRect)
    }
    let signal = min(
      1,
      max(
        0,
        evidence.fillRatio * 0.82
          + evidence.blobFill * 0.10
          + evidence.darkness * 0.08))
    let confidence = min(
      1,
      max(
        0.08,
        0.32
          + evidence.contrast * 0.34
          + evidence.blobFill * 0.12
          + evidence.multiConsistency * 0.10
          + abs(evidence.fillRatio - 0.5) * 0.12))
    return BubbleProbe(
      signal: signal,
      darkness: evidence.darkness,
      confidence: confidence,
      blobFill: evidence.blobFill,
      otsuFill: evidence.otsuFill,
      coverage: evidence.coverage,
      edgeReach: evidence.edgeReach,
      occupancy: evidence.occupancy,
      blobCount: evidence.blobCount,
      multiConsistency: evidence.multiConsistency,
      transformedRect: NormalizedRect(cgRect: transformed))
  }
}
