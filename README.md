# SmartGrade Scanner — OMR Integrity v11

SmartGrade Scanner is a local-first iPhone/iPad answer-sheet reader built with
SwiftUI, SwiftData, Vision, VisionKit, Core Image, AVFoundation, PhotosUI and
PDFKit. It detects the paper, registers a known sheet profile, reads question
bubbles and the Student ID grid, grades against an answer key, and requires human
confirmation whenever the evidence is unsafe.

## The v11 safety rule

The application does not promise impossible zero-error recognition on arbitrary
photos. Instead, it is **fail-closed**:

- a confident, geometrically valid row may be graded automatically;
- a weak, tied, multiply marked, locally shifted or invalid row is not treated as
  a definite student answer;
- flagged rows must be confirmed in Review Scan before Save is enabled;
- an unreadable or low-confidence Student ID forces full-sheet confirmation, which
  also protects against a visually plausible but upside-down/symmetric registration;
- uncertain rows carry no selected choice and cannot silently reduce a grade;
- a blank sheet is valid and does not lose profile-routing score merely because it
  contains no answers.

This is safer than forcing every row to A/B/C/D/E.

## Important v11 corrections

### Page and template integrity

- EXIF orientation is normalized. If orientation metadata was stripped, guarded
  90/180/270-degree recovery is attempted.
- Vision page rectangles, marker-derived page candidates and safe full-frame imports
  are all evaluated. The loop no longer stops before it can compare a clean flat
  import with a marker-derived warp.
- Full-frame scans that already match the sheet are preserved without a second
  perspective deformation.
- Template routing is based on registration geometry, marker coverage, reprojection
  error, image quality and ambiguity—not on how many answers a profile happened to
  invent.
- The landscape reference sheet and portrait legacy demo remain separate profiles.

### Robust registration

- Solid square registration marks require fill, local contrast and dark corners;
  filled circular answers and decorative timing tracks are rejected.
- Ignored page areas are enforced during marker search.
- A deterministic four-point RANSAC-style search evaluates all small homography
  hypotheses, rejects false markers and refits using the inliers.
- Scale, rotation, shear, projective drift, spatial marker coverage and reprojection
  error must remain within guarded limits.
- Slight residual row drift can use a bounded local correction only when at least two
  neighboring probes agree on the same physical bubble. A row using this correction
  is still forced into manual review.

### Bubble decisions

- Question identity is geometric: left-to-right is A, B, C, D, E. OCR never decides
  the answer letter.
- Each bubble is measured at three nearby scales. Median evidence resists one-pixel
  ROI errors; cross-scale disagreement lowers confidence.
- The signal fuses core occupancy, disk occupancy, radial coverage, local darkness
  and local contrast, reducing false marks from printed outlines and letters.
- Capture-specific blank/filled clustering calibrates question bubbles separately
  from the denser Student ID grid.
- Row decisions combine the capture calibration with robust row median/MAD noise,
  absolute evidence, relative lift and winner/runner-up margin.
- Two marks are reported only when both have independent evidence. A tie that is not
  clearly multiple becomes unresolved rather than an invented answer.

### Review and saved results

- Review Scan provides a required answer picker for every flagged row. Save stays
  disabled until all flagged rows are resolved.
- A student can be selected manually when the ID/name does not match the roster.
- The exact detected bounds and successful template profile are persisted with the
  result. Reopening a result no longer redraws overlays using the first/default
  template or pre-alignment coordinates.
- Weak, uncertain and multiple rows are not counted as definite wrong answers;
  questions without an answer key are never labelled right or wrong.
- Stored portrait templates remain portrait when the bundled profile is upgraded.
- Rescanning the same student for the same exam replaces the earlier attempt.

### Capture quality

- Camera capture uses the largest supported photo dimensions and quality priority.
- Focus and exposure receive a short bounded settling period before capture.
- The canonical review image is stored losslessly as PNG.
- VisionKit Document Scanner and original Photos import remain available.

## Bundled sheet profiles

### `ReferenceSheet-591x520-v11`

- landscape ratio `591 / 520`;
- 20 questions: 1–17 in the left block and 18–20 in the upper middle block;
- 4 or 5 choices per configured exam;
- nine Student ID columns × ten digit rows, with prefix `320`;
- nine distributed registration squares.

### `ArabicGeneratedPortrait-v11`

This is compatibility support for the older AI-generated portrait demo. Its physical
ID grid contains seven columns and is not equivalent to the landscape form. The app
will not force one layout through the other's coordinates. OCR is only an ID fallback
when a plausible numeric value has the required prefix; it never supplies answers.

For a new paper design, create an exact matching `TemplateDefinition`. Reusing
coordinates from another form is intentionally rejected.

## Deterministic fixtures

The current reference fixtures are:

- `TestAssets/SmartGradeScanner-v8-Arabic-Valid-Filled.png`
- `TestAssets/SmartGradeScanner-v8-Arabic-Valid-Blank.png`
- `TestAssets/SmartGradeScanner-v7-Perspective-Regression.png`
- `TestAssets/SmartGradeScanner-v8-EXPECTED.txt`
- `TestAssets/SmartGradeScanner-v7-EXPECTED.txt`

The v8 filenames identify when the artwork was generated; the v11 engine deliberately
keeps them as regression inputs instead of renaming and duplicating identical images.

The XCTest suite covers selected/blank/multiple/weak/tied decisions, adaptive faint
marks, Student ID geometry, answer/ID separation, projective recovery with a false
marker, profile routing for blank sheets, exact filled-sheet recognition, blank-sheet
non-invention and missing-orientation recovery.

Run on macOS:

```bash
chmod +x tools/test_ios.sh
./tools/test_ios.sh
```

The GitHub Actions workflow runs these tests before building the IPA.

## Build

1. Open `SmartGradeScanner.xcodeproj` in a recent Xcode that supports Swift 6 and
   iOS 17.
2. Select the `SmartGradeScanner` scheme.
3. Use a physical iPhone/iPad for camera validation.
4. Set your Apple Developer Team/profile for a normally signed archive.

Unsigned device build:

```bash
chmod +x tools/build_ipa.sh
./tools/build_ipa.sh
```

Outputs are written to `IPA_OUTPUT/`. The unsigned IPA must be signed before normal
installation.

## Technical basis

The pipeline follows established document/OMR principles:

- Apple Vision rectangle observations for candidate page localization;
- Core Image perspective correction for photographed documents;
- local/adaptive thresholding for spatially uneven illumination;
- projective registration with outlier rejection before ROI extraction;
- explicit blank/filled/ambiguous classification rather than unconditional argmax.

Relevant primary documentation and research:

- Apple Vision `DetectRectanglesRequest`: https://developer.apple.com/documentation/vision/detectrectanglesrequest
- OpenCV thresholding reference: https://docs.opencv.org/4.x/d7/d1b/group__imgproc__misc.html
- OpenCV geometric transforms: https://docs.opencv.org/4.x/da/d54/group__imgproc__transform.html
- Afifi & Hussain, *The Achievement of Higher Flexibility in Multiple Choice-based
  Tests Using Image Classification Techniques*: https://arxiv.org/abs/1711.00972

The research also shows why simple dark-pixel thresholding cannot honestly guarantee
perfect handling of every crossed-out, erased or unconventional mark. v11 therefore
uses deterministic evidence fusion for the known sheets and mandatory review when
the evidence is insufficient, rather than shipping an untrained “AI” label.
