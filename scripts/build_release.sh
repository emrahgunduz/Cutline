#!/bin/zsh
# Build the optimised (Release) Cutline.app next to the Debug one.
#   scripts/build_release.sh          -> build/Release/Cutline.app
# The bundled analysis runtime (build/ml) is copied in by the same build phase as Debug.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate -q
xcodebuild -project Cutline.xcodeproj -scheme Cutline -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  build > build/release-build.log 2>&1 || { tail -30 build/release-build.log; exit 1; }
mkdir -p build/Release/Cutline.app
# Update the app in place (not delete and copy), so Finder aliases to it keep working.
rsync -a --delete build/DerivedData/Build/Products/Release/Cutline.app/ build/Release/Cutline.app/
echo "Release app: $PWD/build/Release/Cutline.app"
