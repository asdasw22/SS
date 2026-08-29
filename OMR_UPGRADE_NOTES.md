# SmartGradeScanner OMR Ultra v7

This revision replaces the fragile "find one page rectangle, then OMR" pipeline with a marker-first, multi-hypothesis registration pipeline designed for phone-camera captures.

## Root causes fixed

1. **Fast OMR was visually presented as a control but did not reliably capture.** The camera output could receive a request before the AVCaptureSession was running. Fast OMR is now a real Button and waits for the camera session to be configured/running before capture.
2. **Page-edge detection was a hard gate.** If Vision missed the white page border, processing stopped before the black registration squares could help. v7 searches printed square fiducials first and page edges second.
3. **One rectangle was trusted too early.** A monitor, Student ID box, or other rectangle could win. v7 produces several page hypotheses and validates them against the template markers and OMR layout.
4. **The old marker constellation fit used a similarity transform in normalized coordinates.** A landscape sheet inside a portrait camera frame is anisotropically normalized, so that model can select the wrong square constellation. v7 enumerates plausible outer marker quads, solves a true projective homography, and validates the remaining markers.
5. **Identical marker patterns can be 180-degree ambiguous.** v7 orders the outer fiducials as an upright page before homography fitting, preventing the common upside-down false registration.
6. **Document Scanner existed but was not wired into the Scan UI.** v7 exposes VisionKit's native document scanner as a second acquisition path, in addition to Fast OMR and Photos.

## v7 registration pipeline

Camera / Photos / VisionKit scan
-> EXIF orientation normalization
-> connected-component search for solid square fiducials
-> projective marker-homography candidate
-> permissive Apple Vision rectangle candidates
-> optional full-frame scan candidate
-> perspective correction for every candidate
-> marker/template validation
-> best-candidate selection
-> independent question and Student ID calibration
-> row/column-relative bubble decisions
-> confidence and ambiguity safety checks

## Safety behavior

A bad crop is rejected rather than silently graded. Student ID and answer zones remain separate, and a scan with excessive weak/multiple/invalid rows is treated as a template/registration failure.

## Test sheet

`TestAssets/SmartGradeScanner-v6-TestSheet-Filled.png` remains geometrically compatible with v7 because the reference-template coordinates did not change. The registration engine changed; the printed layout did not.
