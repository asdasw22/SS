# OMR Integrity v11 — engineering handoff

## Confirmed failure modes in the supplied v9 project

1. `prepareBestPage` could break after an early strong marker candidate. This meant
   the later full-frame candidate was never evaluated, despite code that claimed a
   clean flat import was preferred.
2. Auto-profile routing rewarded the ratio of `.selected` rows. A wrong profile that
   manufactured answers could therefore beat a correct profile on a blank sheet.
3. `ResultDetailView` always requested the first candidate template. Portrait results
   could be redrawn with landscape coordinates.
4. Saved responses did not persist post-registration bounds, so local/projective
   correction was lost when an overlay was recreated.
5. `.uncertain` could still carry a selected letter, and weak/uncertain rows could be
   counted as wrong despite never being confirmed.
6. The existing XCTest assertions still expected v8 profiles while the code emitted
   v9, and CI built the IPA without running tests.
7. README referenced v9 fixture filenames that did not exist.

## Implemented v11 protections

- evaluate every page candidate before choosing the flat/rectified winner;
- safe right-angle recovery for images with missing orientation metadata;
- geometry-first template routing with no selected-answer reward;
- deterministic exhaustive four-marker projective consensus and outlier refit;
- three-scale median bubble measurement and stability-aware confidence;
- calibration-aware classification using row median/MAD, lift and margin;
- no selected choice for an unresolved tie;
- two-probe consensus before local row correction, followed by mandatory review;
- mandatory resolution of flagged questions before saving;
- full-sheet confirmation whenever the Student ID geometry cannot be trusted;
- correct profile and exact detected bounds persisted for later overlays;
- lossless canonical review image;
- guarded OCR Student ID prefix;
- orientation-preserving upgrades for previously stored built-in templates;
- distinct wrong/multiple/unresolved counters, with no wrong label when no key exists;
- updated model version, tests, documentation and CI test gate.

## Validation boundary

The included automated fixtures validate the bundled sheet geometries. A photograph
with glare over a mark, a folded/occluded page, a non-matching form, or unconventional
erasures can remain ambiguous. The correct behavior in those cases is a rejected scan
or required human review—not a confident guessed grade.
