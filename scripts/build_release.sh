#!/bin/zsh
# Build the Release Cutline.app, zip it, and smoke-test it. Local builds and the GitHub
# Release workflow both run this script.
#
#   scripts/build_release.sh             build (makes the Python runtime only when it's missing or its lock changed)
#   scripts/build_release.sh --clean     rebuild everything, including the Python runtime (keeps build/ml/models)
#   scripts/build_release.sh --no-smoke  skip the offline analysis check (about 30 s; it needs the models)
#   scripts/build_release.sh --open      open the app when done
#
# Result: build/Release/Cutline.app (ad-hoc signed; it downloads its models on first launch),
# build/Release/Cutline.app.dSYM, build/Release/Cutline.zip and Cutline.zip.sha256.
# Version: 1.0.<n>. Local builds count up in build/build-number; CI passes APP_VERSION and APP_BUILD.
set -euo pipefail
root=${0:A:h:h}
cd $root
clean=0 smoke=1 open_app=0
for arg in "$@"; do
  case $arg in
    --clean) clean=1 ;;
    --no-smoke) smoke=0 ;;
    --open) open_app=1 ;;
    -h|--help) sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg (see scripts/build_release.sh --help)" >&2; exit 2 ;;
  esac
done

missing=()
command -v uv >/dev/null || missing+=("uv (brew install uv)")
command -v xcodegen >/dev/null || missing+=("xcodegen (brew install xcodegen)")
xcodebuild -version >/dev/null 2>&1 || missing+=("Xcode, selected with: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer")
if (( ${#missing} )); then
  echo "Missing tools:" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 1
fi
[[ $(uname -m) == arm64 ]] || { echo "Cutline is built for Apple Silicon (arm64) only." >&2; exit 1; }

out=build/Release
if (( clean )); then
  echo "==> Clean build"
  rm -rf build/DerivedData $out
fi

echo "==> Python runtime (build/ml/python)"
scripts/build_python_runtime.sh --no-models ${${clean:#0}:+--clean} > build/runtime-build.log 2>&1 \
  || { tail -30 build/runtime-build.log; exit 1; }
grep -E "build/ml/python$" build/runtime-build.log | tail -1 || true

if (( smoke )); then
  # The offline check needs the models the app would download. Resumable; quick when complete.
  echo "==> Models for the smoke test (build/ml/models)"
  build/ml/python/bin/python3 -s scripts/fetch_models.py build/ml/models | tail -1
fi

version_args=()
[[ -n ${APP_VERSION:-} ]] && version_args=(APP_VERSION=$APP_VERSION APP_BUILD=${APP_BUILD:-${APP_VERSION##*.}})
echo "==> Xcode Release build${APP_VERSION:+ (version $APP_VERSION)}"
xcodegen generate -q
xcodebuild -project Cutline.xcodeproj -scheme Cutline -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData \
  build "${version_args[@]}" > build/release-build.log 2>&1 || { tail -30 build/release-build.log; exit 1; }
built=build/DerivedData/Build/Products/Release/Cutline.app

mkdir -p $out
# Update the app in place (not delete and copy), so Finder aliases to it keep working.
rsync -a --delete $built/ $out/Cutline.app/
# Symbols for crash logs (the app's binary is stripped).
rm -rf $out/Cutline.app.dSYM
[[ -d $built.dSYM ]] && cp -a $built.dSYM $out/
app=$out/Cutline.app
# Re-seal: Xcode can keep an earlier signature when only bundled resources changed.
codesign --force --sign - $app
codesign --verify --deep --strict $app || { echo "error: the app's signature does not verify" >&2; exit 1; }
version=$(defaults read "$PWD/$app/Contents/Info" CFBundleShortVersionString)
echo "signature: ok (ad-hoc), version $version, $(du -sh $app | cut -f1)"

echo "==> $out/Cutline.zip"
rm -f $out/Cutline.zip $out/Cutline.zip.sha256
(cd $out && ditto -c -k --sequesterRsrc --keepParent Cutline.app Cutline.zip && shasum -a 256 Cutline.zip > Cutline.zip.sha256)
ls -lh $out/Cutline.zip | awk '{print "zip: " $5}'

echo "==> Smoke test"
if (( smoke )); then
  scripts/smoke_test.sh $app build/ml/models
else
  scripts/smoke_test.sh $app
fi

echo "Built: $root/$app (version $version)"
(( open_app )) && open $app
exit 0
