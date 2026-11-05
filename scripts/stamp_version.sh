#!/bin/zsh
# Build phase: every build (Debug or Release) takes the next build number from BUILD_NUMBER
# and stamps the built app's Info.plist as VERSION_BASE.<n> (1.0.1, 1.0.2, ...).
# Runs before code signing, so the signature covers the stamped version.
set -euo pipefail
FILE="$SRCROOT/BUILD_NUMBER"
N=$(( $(cat "$FILE" 2>/dev/null || echo 0) + 1 ))
echo "$N" > "$FILE"
PLIST="$TARGET_BUILD_DIR/$INFOPLIST_PATH"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION_BASE:-1.0}.$N" -c "Set :CFBundleVersion $N" "$PLIST"
echo "Cutline ${VERSION_BASE:-1.0}.$N ($CONFIGURATION)"
