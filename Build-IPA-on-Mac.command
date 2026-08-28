#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"
"$HERE/tools/build_ipa.sh"
STATUS=$?
echo ""
if [[ $STATUS -eq 0 ]]; then
  echo "Finished. Open the IPA_OUTPUT folder to get the IPA."
else
  echo "Build failed with exit code $STATUS. Check IPA_OUTPUT/build.log."
fi
echo ""
read -r -p "Press Enter to close..." _
exit $STATUS
