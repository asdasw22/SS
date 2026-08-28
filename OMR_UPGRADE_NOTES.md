# SmartGradeScanner OMR Ultra v6

This revision targets the exact failure visible in the test screenshots: an inner Student ID table was being accepted as the whole document, stretched to the page template, and then its digits/grid lines were interpreted as A/B/C/D/E answers.

## v6 changes

- Whole-page fast path runs before Vision rectangle detection for already-cropped scans/photos.
- Inner rectangles are rejected: a detected page must occupy at least ~40% of the camera image.
- The old VisionKit manual `Document` crop button is removed from the scanning flow. Use the normal shutter or Photos; no manual border selection is required.
- Registration markers now require a solid-square signature, including dark corners. Filled circular answer bubbles can no longer impersonate page markers.
- Strict templates require widely distributed markers across the sheet.
- Bubble analysis uses a glyph-resistant elliptical ring. Printed A/B/C/D/E and 0-9 characters in empty bubbles no longer dominate the mark signal.
- Multiple answers require two genuinely strong, near-tied marks. A clearly strongest bubble wins even if a printed glyph makes a second bubble moderately dark.
- Student ID uses the same relative-best logic and remains completely separate from question zones.
- Strict scans with widespread ambiguous rows now fail immediately instead of returning a garbage review screen.
- Image normalization no longer upscales small clean scans to 2200 px; maximum processing long edge is 1600 px, improving speed.
- Bundled reference template revision is now 6 and upgrades older bundled templates automatically.

## Reference-sheet regression check

The v6 ring metric was checked against the supplied 591 x 520 reference image. It recovered all 20 strongest answer bubbles and recovered Student ID `320234561204` exactly in the local regression harness.

For best results, keep the complete white sheet and all black registration squares visible in the frame. Do not crop around the Student ID table or answer area.
