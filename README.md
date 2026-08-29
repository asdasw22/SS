# SmartGrade Scanner — robust OMR build

SmartGrade Scanner is a local-first iOS/iPadOS optical-mark reader built with SwiftUI, SwiftData, Vision, VisionKit, Core Image, AVFoundation, PhotosUI, and PDFKit.

## What was strengthened

The OMR path is deliberately **fail-closed**: when alignment, Student ID, image quality, or a mark is ambiguous, the app flags the result for review instead of silently guessing.

- EXIF orientation is normalized before geometry analysis.
- Vision rectangle detection ranks candidates by page confidence, expected sheet aspect ratio, size, and centering.
- Images already cropped by VisionKit can use a guarded full-frame fallback instead of failing because there is no outer background.
- Perspective correction renders every sheet to a canonical page size before template coordinates are applied.
- The included sheet profile was recalibrated from the supplied reference sheet: landscape page ratio, 20 answer rows, the 9×10 Student ID grid, and nine registration markers.
- Registration markers are detected as dark, locally contrasted, approximately solid squares — not merely the darkest nearby patch.
- Marker correspondences drive a robust affine template correction with outlier rejection and reprojection-error checks.
- Answer and Student ID regions are geometrically separated and validated before reading, preventing the ID grid from being interpreted as answer bubbles.
- Bubble darkness uses a local background estimate rather than a hard-coded global grayscale threshold.
- Question bubbles and Student ID cells are calibrated independently per capture, so the dense numeric grid cannot shift the answer threshold.
- Bubble analysis uses an inner elliptical mask, reducing false marks from the printed circle outline and option glyphs.
- The sheet calibrates blank-vs-filled signal clusters per capture (two-cluster calibration), which handles shadows, different printers, pens, and exposure changes substantially better than a fixed threshold.
- Student ID columns require one clearly dominant digit; ambiguous columns are rejected rather than guessed.
- A failed reference-sheet alignment is never retried with a different physical layout; this specifically prevents Student ID rows from being reinterpreted as A/B/C/D/E answers.
- Image quality has usable/ideal bands. Borderline photos can still be processed but are explicitly marked for review.
- Camera capture prioritizes photo quality and continuous focus/exposure/white balance.
- The review screen displays the aligned sheet, Student ID confidence, correct answer, per-question status, and optional developer overlays with every bubble signal and registration diagnostic.
- The custom Info.plist now contains the required bundle metadata for normal IPA signing tools.
- A complete AppIcon asset is included.

## Reference profile

The bundled `SampleDataSeeder.template()` is calibrated to the supplied reference answer sheet:

- 20 questions
- 4 or 5 choices (`A...D` / `A...E`), with unused physical columns excluded from scanning
- Questions 1–17 in the left answer block
- Questions 18–20 in the upper middle block
- 9 Student ID columns × 10 digit rows
- Student ID prefix `320`
- 9 registration markers
- reference page width/height = `591/520`

If a different paper design is used, its exact bubble and marker positions still need a matching `TemplateDefinition`; no safe OMR system can infer arbitrary layouts from coordinates belonging to another form.

## Engineering basis

The implementation follows the same core principles used in established document/OMR pipelines:

- Apple Vision rectangle observations and configurable aspect/size/quadrature filtering for document localization.
- Apple Core Image perspective correction for rectifying photographed sheets.
- Apple Image I/O orientation metadata so portrait camera captures are analyzed in their intended orientation.
- Apple VisionKit document scanning as the preferred user-assisted capture path.
- Adaptive/local thresholding concepts used by OpenCV for non-uniform illumination.
- Perspective registration, ROI segmentation, adaptive thresholding, and morphology/mark-separation approaches reported in modern OMR literature and large phone-camera OMR evaluations.

## Open and build

1. Open `SmartGradeScanner.xcodeproj` in Xcode 26.6 (or a compatible recent Xcode).
2. Select the `SmartGradeScanner` scheme.
3. For camera testing, run on a physical iPhone/iPad.
4. For normal signed distribution, choose your Apple Developer Team and signing profile.
5. The included GitHub Actions workflow builds an unsigned device `.app`/IPA and validates required Info.plist metadata.

## Tests

`SmartGradeScannerTests` covers:

- selected / empty / weak / multiple / low-confidence bubble decisions
- adaptive calibration behavior
- Student ID grid definition and answer/ID region separation
- weighted grading
- normalized-coordinate stability
- perspective error measurement
- affine marker alignment recovery

## OMR Ultra v8 note

v8 addresses the real-device case where the sheet was visibly aligned but many rows were still reported as `Multiple`/`Empty`. The scanner now distinguishes the bundled 591 x 520 landscape sheet from the separate portrait Arabic demo sheet instead of forcing both through one coordinate map. It also replaces raw interior-ink counting with radial-sector coverage, then uses row-local gap/noise classification before accepting A/B/C/D/E.

For a deterministic end-to-end test, use `TestAssets/SmartGradeScanner-v8-Arabic-Valid-Filled.png` and compare with `TestAssets/SmartGradeScanner-v8-EXPECTED.txt`. The valid sheet contains nine Student-ID columns and encodes `320234561204`.

The old AI-generated portrait demo is kept compatible for answer detection, but its printed Student-ID grid is physically malformed (seven columns and an ambiguous column), so v8 may use OCR of its printed numeric ID after rejecting the ambiguous grid.

For scoring rather than mark detection only, open **Exams > Science Quiz > camera icon**. `Quick Scan` has no answer key by design.

## v8.1 scan geometry and automatic student marks

- Clean Photos/scanner images are no longer perspective-corrected again. If the whole image already matches the sheet orientation/aspect, SmartGradeScanner preserves its pixels and only resizes uniformly.
- Full-frame pages with valid registration marks are preferred over a second marker-derived warp, preventing the visible trapezoid/skew that could appear in Review Scan.
- Template orientation matching is now strict: a portrait page is not silently accepted as the reciprocal of a landscape profile unless a real rotation path exists.
- Marker-derived page recovery now validates the recovered page aspect in pixel geometry before any warp is accepted.
- Review Scan automatically matches the detected Student ID to the local roster and displays the student's name. Fast OCR text is used only as a high-confidence roster fallback when the ID is unclear.
- Saving a scan attaches the mark to that Student and Exam. Rescanning the same student for the same exam replaces the previous mark instead of creating a duplicate.
- Students now have a detail screen showing saved exam marks.
- The Home scan button and Scan tab now use the most recent exam with an answer key automatically, so Quick Scan produces a real score and Save assigns it to the matched student without requiring an extra exam-selection step.
