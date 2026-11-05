#!/bin/zsh
# Build phase: stamps the built app's Info.plist as 1.0.<n> (CFBundleShortVersionString)
# and <n> (CFBundleVersion). Runs before code signing, so the signature covers the stamp.
#
# <n> is APP_BUILD when the build passes it (the GitHub Release workflow uses its run
# number, with APP_VERSION=1.0.<run number>). Otherwise every local build (Debug, Release,
# tests) takes the next number from build/build-number, which isn't tracked in git.
set -euo pipefail
if [[ -n ${APP_VERSION:-} ]]; then
  VERSION=$APP_VERSION
  N=${APP_BUILD:-${APP_VERSION##*.}}
else
  FILE="$SRCROOT/build/build-number"
  mkdir -p "${FILE:h}"
  N=$(( $(cat "$FILE" 2>/dev/null || echo 0) + 1 ))
  echo "$N" > "$FILE"
  VERSION=${VERSION_BASE:-1.0}.$N
fi
PLIST="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $N" "$PLIST"
echo "Cutline $VERSION ($CONFIGURATION)"
