#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${ROOT_DIR}"

PROJECT="SmartGradeScanner.xcodeproj"
TARGET="SmartGradeScanner"
APP_NAME="SmartGradeScanner"
BUNDLE_ID="com.smartgrade.scanner"
CONFIGURATION="Release"
BUILD_DIR="${ROOT_DIR}/build"
OUTPUT_DIR="${ROOT_DIR}/IPA_OUTPUT"
LOG_FILE="${OUTPUT_DIR}/build.log"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "ERROR: xcodebuild was not found. Build this project on macOS with Xcode installed."
  exit 2
fi

if [[ ! -d "${PROJECT}" || ! -f "${PROJECT}/project.pbxproj" ]]; then
  echo "ERROR: ${PROJECT} is missing or incomplete."
  exit 3
fi

rm -rf "${BUILD_DIR}" "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"

XCODE_VERSION="$(xcodebuild -version | sed -n '1p')"
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"

echo "============================================================"
echo "SmartGradeScanner IPA Builder"
echo "Xcode: ${XCODE_VERSION}"
echo "iPhoneOS SDK: ${SDK_VERSION}"
echo "Configuration: ${CONFIGURATION}"
echo "Code signing: disabled"
echo "============================================================"

xcodebuild \
  -project "${PROJECT}" \
  -target "${TARGET}" \
  -configuration "${CONFIGURATION}" \
  -sdk iphoneos \
  SYMROOT="${BUILD_DIR}" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  DEVELOPMENT_TEAM="" \
  PRODUCT_BUNDLE_IDENTIFIER="${BUNDLE_ID}" \
  clean build \
  2>&1 | tee "${LOG_FILE}"

APP_PATH="$(find "${BUILD_DIR}" -type d -name "${APP_NAME}.app" -path '*Release-iphoneos*' -print -quit)"
if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" ]]; then
  echo "ERROR: Built ${APP_NAME}.app was not found."
  exit 4
fi

rm -rf "${APP_PATH}/_CodeSignature"
rm -f "${APP_PATH}/embedded.mobileprovision"

INFO_PLIST="${APP_PATH}/Info.plist"
if [[ ! -f "${INFO_PLIST}" ]]; then
  echo "ERROR: Built application is missing Info.plist."
  exit 5
fi

for key in CFBundleIdentifier CFBundleExecutable CFBundlePackageType CFBundleShortVersionString CFBundleVersion; do
  if ! /usr/libexec/PlistBuddy -c "Print :${key}" "${INFO_PLIST}" >/dev/null 2>&1; then
    echo "ERROR: Missing required Info.plist key: ${key}"
    exit 6
  fi
done

PAYLOAD_DIR="${OUTPUT_DIR}/Payload"
mkdir -p "${PAYLOAD_DIR}"
cp -R "${APP_PATH}" "${PAYLOAD_DIR}/${APP_NAME}.app"

IPA_PATH="${OUTPUT_DIR}/${APP_NAME}-unsigned.ipa"
APP_ZIP_PATH="${OUTPUT_DIR}/${APP_NAME}-unsigned.app.zip"

if command -v ditto >/dev/null 2>&1; then
  (
    cd "${OUTPUT_DIR}"
    ditto -c -k --sequesterRsrc --keepParent Payload "${IPA_PATH}"
  )
  ditto -c -k --sequesterRsrc --keepParent "${PAYLOAD_DIR}/${APP_NAME}.app" "${APP_ZIP_PATH}"
else
  (
    cd "${OUTPUT_DIR}"
    zip -qry "${IPA_PATH}" Payload
  )
  (
    cd "${PAYLOAD_DIR}"
    zip -qry "${APP_ZIP_PATH}" "${APP_NAME}.app"
  )
fi

unzip -t "${IPA_PATH}" >/dev/null
if ! unzip -l "${IPA_PATH}" | grep -q "Payload/${APP_NAME}.app/"; then
  echo "ERROR: IPA structure is invalid."
  exit 7
fi

BUNDLE_IDENTIFIER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "${INFO_PLIST}")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${INFO_PLIST}")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${INFO_PLIST}")"

cat > "${OUTPUT_DIR}/BUILD-METADATA.txt" <<META
Application: ${APP_NAME}
Bundle Identifier: ${BUNDLE_IDENTIFIER}
Version: ${VERSION}
Build: ${BUILD_NUMBER}
Xcode: ${XCODE_VERSION}
iPhoneOS SDK: ${SDK_VERSION}
Code Signing: Disabled
Output IPA: ${IPA_PATH}
META

printf '\n============================================================\n'
printf 'IPA CREATED SUCCESSFULLY\n'
printf '============================================================\n'
printf 'IPA: %s\n' "${IPA_PATH}"
printf 'APP ZIP: %s\n' "${APP_ZIP_PATH}"
printf 'This IPA is unsigned and must be signed before installation.\n'
