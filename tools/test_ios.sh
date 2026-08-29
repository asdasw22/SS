#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROJECT="${ROOT_DIR}/SmartGradeScanner.xcodeproj"
SCHEME="SmartGradeScanner"
OUTPUT_DIR="${ROOT_DIR}/TEST_OUTPUT"
DERIVED_DATA="${ROOT_DIR}/build-tests"
LOG_FILE="${OUTPUT_DIR}/tests.log"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "ERROR: xcodebuild was not found. Run tests on macOS with Xcode installed."
  exit 2
fi

rm -rf "${OUTPUT_DIR}" "${DERIVED_DATA}"
mkdir -p "${OUTPUT_DIR}"

DESTINATION_LINE="$(
  xcodebuild -project "${PROJECT}" -scheme "${SCHEME}" -showdestinations 2>/dev/null \
    | awk '/platform:iOS Simulator/ && !/Any iOS Simulator Device/ { print; exit }'
)"
DESTINATION_ID="$(printf '%s' "${DESTINATION_LINE}" | sed -E 's/.*id:([^,}]+).*/\1/' | xargs)"

if [[ -z "${DESTINATION_ID}" || "${DESTINATION_ID}" == "${DESTINATION_LINE}" ]]; then
  echo "ERROR: No usable iOS Simulator destination was found."
  exit 3
fi

xcodebuild \
  -project "${PROJECT}" \
  -scheme "${SCHEME}" \
  -configuration Debug \
  -destination "id=${DESTINATION_ID}" \
  -derivedDataPath "${DERIVED_DATA}" \
  CODE_SIGNING_ALLOWED=NO \
  test \
  2>&1 | tee "${LOG_FILE}"

