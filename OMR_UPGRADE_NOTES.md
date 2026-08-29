# SmartGradeScanner OMR Ultra v8

v8 fixes the remaining failure seen in the real-device screenshots: the page could be aligned correctly but the answers were still reported as `Multiple`, `Empty`, or the wrong letter.

## Root cause confirmed from the test sheet

Two different physical sheet layouts had been mixed together:

1. The bundled reference template is a **591 x 520 landscape** form with 9 Student-ID digit columns.
2. The AI-generated Arabic demo image used during testing is a **1054 x 1492 portrait** form. Its bubbles and markers are in different coordinates. Its Student-ID bubble table physically contains only **7 columns**, and one column contains two filled marks even though the printed text says `320234561204`.

Forcing the portrait image through the landscape coordinates can produce believable but wrong answers. v8 never treats those layouts as the same template.

## v8 OMR pipeline

### 1. Multi-profile routing

For the bundled/demo scanner, every image is evaluated against two known profiles:

- `ReferenceSheet-591x520-v8`
- `ArabicGeneratedPortrait-v8`

The result with the strongest registration, selected-answer ratio, ambiguity ratio and Student-ID evidence wins. A user-created custom template is never silently replaced by another profile.

### 2. Radial-sector bubble measurement

An empty answer bubble already contains dark ink from the printed circle and the A/B/C/D/E glyph. Raw dark-pixel percentage therefore creates false multiple answers.

v8 measures a mid-interior annulus, ignores most of the center glyph and outer border, divides the annulus into angular sectors, and scores **distributed dark coverage**. A true filled bubble darkens almost every sector; a printed glyph darkens only a few.

### 3. Row-local classification

Each question is classified from its own A-E population. v8 estimates the blank baseline and noise of that row, then requires a meaningful lift and margin before selecting a response. Two answers are marked `Multiple` only when both are independently strong and close to the strongest value.

### 4. Student ID stays independent

Question bubbles and Student-ID cells use separate calibration populations and separate parsers. If the legacy portrait demo's malformed seven-column ID grid is ambiguous, Vision OCR may recover the clearly printed numeric ID as a secondary fallback. The bubble grid remains the primary source on a valid sheet.

### 5. Marker-first acquisition remains

v8 keeps v7's marker-first registration, multi-candidate page detection, homography alignment, Fast OMR capture and VisionKit Document Scanner. Page-edge detection is helpful but is not a hard gate.

## Deterministic test assets

Use these files rather than an AI-generated sheet when validating accuracy:

- `TestAssets/SmartGradeScanner-v8-Arabic-Valid-Filled.png`
- `TestAssets/SmartGradeScanner-v8-Arabic-Valid-Blank.png`
- `TestAssets/SmartGradeScanner-v8-EXPECTED.txt`

The filled sheet has an internally valid 9-column Student-ID grid and exact coordinates matching `ReferenceSheet-591x520-v8`.

Expected Student ID: `320234561204`

Expected answers:

`1:C 2:A 3:D 4:B 5:E 6:C 7:D 8:B 9:A 10:E 11:C 12:B 13:D 14:A 15:C 16:E 17:B 18:D 19:A 20:C`

## Recommended validation sequence

1. First import `SmartGradeScanner-v8-Arabic-Valid-Filled.png` from Photos. This isolates OMR from camera acquisition.
2. Then display/print the same sheet and scan it with Fast OMR.
3. Then try the VisionKit Document Scanner.
4. Enable Debug Mode only if a field is flagged; inspect the selected `OMR profile` and per-bubble signals.
5. For actual scoring, open **Exams > Science Quiz > camera icon**. Quick Scan intentionally detects marks without an answer key.

The bundled fresh-install `Science Quiz` answer key now matches the deterministic v8 filled test sheet exactly.

### v8.1
- Preserve full-frame imported scans without perspective deformation.
- Direct-orientation aspect matching only; reciprocal aspect ratios are rejected unless an actual rotation is performed.
- Pixel-geometry aspect validation added to fiducial homography recovery.
- Exact Student ID -> roster name matching, OCR name fallback, and automatic grade association on Save.
- Duplicate same-student/same-exam scans are replaced.
- Student detail screen lists saved marks.
- Quick Scan now resolves the most recent exam with an answer key, enabling immediate scoring and roster assignment from the Scan tab.

## v9 - Spatial Visual Fusion + Strict Profile Lock
- Built-in sheets no longer accept a plausible screen/window rectangle when registration squares do not match. This prevents the landscape sheet from being stretched into the portrait profile.
- Answer identity is now spatial for built-in sheets: left-to-right bubbles map to A, B, C, D, E. OCR never decides the selected answer.
- Bubble evidence now fuses core dark occupancy, disk occupancy, radial coverage, local contrast and darkness instead of relying mainly on the annulus.
- Row classification uses both absolute fill and the relative jump from neighboring bubbles. A clear mark can be selected even under exposure changes, while blank rows remain blank because no cell separates from the row baseline.
- Multiple answers require two independently strong fills; printed letters, JPEG ringing and monitor moire are not enough.
- Slight ROI expansion tolerates sub-pixel page-registration drift without crossing into the neighboring bubble cell.
- Auto-profile routing gives substantial weight to distributed registration markers and marker-first recovery.
- Existing bundled templates are upgraded to revision 9.

## v10 - Homography Registration Fix (marker-far bubbles reading as Empty)
- Root cause found from the reported screenshots: rows near a registration marker
  (e.g. Q8-Q10 on the bundled test sheet) registered correctly while rows farther
  from every marker (Q1-Q7, Q11-Q17) were consistently read as Empty even though
  they were clearly filled. The second-stage marker refinement in
  `TemplateAlignmentService` was fitting a plain 6-DOF affine transform. A real
  photographed sheet keeps residual perspective/keystone distortion after the
  first corner-based correction, which an affine map cannot represent; the error
  grows with distance from the marker cluster, which is exactly the symptom seen.
- `TemplateAlignmentService` now refits a full projective transform with the
  existing `HomographySolver` whenever 4+ inlier markers survive outlier
  rejection (falling back to affine only when markers are sparse). This is the
  primary fix.
- `TemplateDefinition.ignoredAreas` was defined but never actually used anywhere
  in the pipeline. It is now passed into `MarkerDetectionService`, so decorative
  page furniture (for example the small guide-square column printed next to
  Q10-Q17 on the v6/v7 test sheets) can no longer be mistaken for a registration
  marker and quietly bias the transform.
- Added a bounded local per-row re-registration search in `OMRProcessor` as a
  second line of defense: it only activates when a row's own zero-offset reading
  looks weak/flat, tries a small rigid shift, and only adopts a shift that
  produces a clearly stronger and cleaner single-bubble peak than the original
  reading. It never invents an answer from noise, and it flags the scan for
  review when it fires so a human still double-checks the affected rows.
