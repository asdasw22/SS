SmartGradeScanner v11 regression assets (fixture artwork retains its v7/v8 filename)

PRIMARY VALIDATION
------------------
SmartGradeScanner-v8-Arabic-Valid-Filled.png
- deterministic, programmatically drawn
- exact ReferenceSheet-591x520 geometry, currently consumed by the v11 profile
- 9 valid Student-ID suffix columns
- ID: 320234561204
- expected results: SmartGradeScanner-v8-EXPECTED.txt

SmartGradeScanner-v8-Arabic-Valid-Blank.png
- same exact geometry without marks
- useful for blank-baseline and false-positive testing

V8-SIGNAL-VALIDATION.txt
- independent regression measurement of the new radial-sector bubble signal
- verifies all 20 answers and Student ID on the deterministic sheet
- also records the physically ambiguous ID column in the legacy portrait AI sheet

LEGACY-AI-PORTRAIT-NOTE.txt
- explains why the old AI-generated portrait image cannot be treated as a valid ID bubble grid

HISTORICAL V7 ASSETS
--------------------
The v7 files remain for perspective/registration regression comparisons. Prefer the
v8 deterministic filled and blank artwork for current bubble-classification tests.
The v11 XCTest suite reads these files directly and CI runs it before the IPA build.
