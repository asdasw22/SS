# SmartGrade Scanner v11 — validation report

## Completed in this workspace

- Inspected all OMR, camera, template, review, persistence and test code.
- Verified shell syntax for `tools/build_ipa.sh` and `tools/test_ios.sh`.
- Verified the original archive and all bundled PNG fixtures are readable.
- Verified the Xcode project has unique object identifiers and balanced OpenStep
  project delimiters after adding the test resources.
- Verified Swift source delimiter balance across 57 application files and five test
  files.
- Checked for stale v8/v9 profile assertions and nonexistent v9 fixture references.
- Added regression coverage for portrait-preserving built-in profile upgrades and
  distinct wrong/multiple/unkeyed result counts.
- Recomputed the v11 three-scale bubble evidence independently from the supplied
  reference fixture.

## Pixel stress result

The expected answer remained correct for all 20 rows in every tested variant:

| Variant | Correct | Minimum winner margin | Average margin |
| --- | ---: | ---: | ---: |
| Original | 20/20 | 0.762 | 0.785 |
| Gaussian blur 1.2 | 20/20 | 0.662 | 0.676 |
| Gaussian blur 2.0 | 20/20 | 0.532 | 0.550 |
| Brightness 65% | 20/20 | 0.760 | 0.783 |
| Brightness 125% | 20/20 | 0.752 | 0.776 |
| Contrast 65% | 20/20 | 0.712 | 0.734 |
| Half resolution | 20/20 | 0.744 | 0.767 |
| JPEG quality 42 | 20/20 | 0.695 | 0.729 |

This stress check validates the ROI signal/class separation on the supplied artwork.
It does not replace the iOS Vision/Core Image integration tests.

## XCTest and CI gate added

The 31-test suite now includes end-to-end filled, blank, sideways-orientation and
perspective fixture cases, plus a false-marker projective registration case. The
fixture folder is copied into the test bundle. GitHub Actions runs `tools/test_ios.sh`
before `tools/build_ipa.sh` using the latest stable installed Xcode; a failing
regression prevents IPA publication.

## Environment boundary

This Linux workspace does not contain Xcode, `xcodebuild`, the iOS SDK or an iOS
Simulator, so the Swift/iOS test target and device IPA cannot be executed locally.
Run `./tools/test_ios.sh` on macOS (or the included GitHub Actions workflow) for the
authoritative compile and integration result. No claim of a locally completed Xcode
build is made in this report.
