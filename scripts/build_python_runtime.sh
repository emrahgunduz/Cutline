#!/bin/zsh
# Builds the helper's Python runtime into build/ml/python, and downloads the models into
# build/ml/models for development and tests. An Xcode build phase copies the runtime and
# helper/cutline_helper into Cutline.app/Contents/Resources/ml. The models are NOT bundled:
# the app downloads them (New Project screen, Settings > Models) into a folder the user picks.
#
#   scripts/build_python_runtime.sh          build runtime + models (skips parts already done)
#   scripts/build_python_runtime.sh --clean  start over
#   scripts/build_python_runtime.sh --lock   re-resolve helper/requirements.lock
set -euo pipefail
ROOT=${0:A:h:h}
ML=$ROOT/build/ml
PY_VERSION=3.12.16
# Keep uv's own downloads and caches inside build/, not in ~/.cache.
export UV_CACHE_DIR=$ROOT/build/uv-cache
export UV_PYTHON_INSTALL_DIR=$ROOT/build/uv-python
export UV_NO_CONFIG=1

if [[ ${1:-} == --lock ]]; then
  uv pip compile $ROOT/helper/requirements.in --override $ROOT/helper/overrides.txt \
    --python-version 3.12 --python-platform aarch64-apple-darwin --generate-hashes \
    -o $ROOT/helper/requirements.lock
  exit 0
fi
[[ ${1:-} == --clean ]] && rm -rf $ML $UV_PYTHON_INSTALL_DIR

mkdir -p $ML
if [[ ! -x $ML/python/bin/python3 ]]; then
  echo "==> python-build-standalone $PY_VERSION"
  uv python install $PY_VERSION
  src=$(echo $UV_PYTHON_INSTALL_DIR/cpython-$PY_VERSION-macos-aarch64-none)
  rm -rf $ML/python
  cp -R $src $ML/python
  rm -f $ML/python/lib/python3.12/EXTERNALLY-MANAGED
fi
PY=$ML/python/bin/python3

LOCK_HASH=$(shasum -a 256 $ROOT/helper/requirements.lock | cut -d' ' -f1)
if [[ $(cat $ML/.packages 2>/dev/null) != $LOCK_HASH ]]; then
  echo "==> packages from helper/requirements.lock"
  uv pip install --python $PY --compile-bytecode -r $ROOT/helper/requirements.lock
  echo $LOCK_HASH > $ML/.packages
fi

if [[ ! -f $ML/models/.complete ]]; then
  mkdir -p $ML/models
  $PY -s $ROOT/scripts/fetch_models.py $ML/models
fi

# Test-only packages live outside the bundle.
if [[ ! -d $ROOT/build/ml-dev/pytest ]]; then
  uv pip install --python $PY --target $ROOT/build/ml-dev pytest -q
fi
du -sh $ML/python $ML/models
echo "==> done. Helper tests: PYTHONPATH=build/ml-dev build/ml/python/bin/python3 -B -m pytest -c helper/pytest.ini --rootdir helper helper/tests"
