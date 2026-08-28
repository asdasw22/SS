# SmartGradeScanner IPA Builder

This package includes two ways to generate a real unsigned iOS IPA from the Xcode project.

## Method 1 - GitHub Actions

The repository already contains `.github/workflows/build-ios-ipa.yml`.
When the project is pushed to `main` or `master`, GitHub automatically builds it on macOS/Xcode and uploads `SmartGradeScanner-unsigned.ipa` as an artifact. It can also be started manually with **Run workflow**.

## Method 2 - Mac with Xcode

Double-click `Build-IPA-on-Mac.command`, or run:

```bash
./tools/build_ipa.sh
```

The generated files appear in `IPA_OUTPUT/`.

The IPA is unsigned by design. Sign it with your preferred legitimate signing method before installing it on an iPhone or iPad.
