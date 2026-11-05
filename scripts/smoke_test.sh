#!/bin/zsh
# Smoke test of a built Cutline.app: its bundled analysis helper must run in a clean
# environment and refuse the network. With a models folder, it also analyses a short
# synthetic song and aligns lyrics on it, with internet access blocked by sandbox-exec.
#
#   scripts/smoke_test.sh <Cutline.app> [models_dir]
#
# Exits non-zero if anything fails.
set -euo pipefail
here=${0:A:h}
app=${1:A}
models=${2:+${2:A}}
res=$app/Contents/Resources/ml
py=$res/python/bin/python3
[[ -x $py ]] || { echo "smoke: no bundled Python in $app" >&2; exit 1; }
tmp=$(mktemp -d)
trap 'rm -rf $tmp' EXIT

# One helper job: request JSON on stdin, prints the last protocol line.
job() {
  local request=$1 sandbox=${2:-}
  local cmd=($py -E -s -B -m cutline_helper)
  [[ -n $sandbox ]] && cmd=(sandbox-exec -f $here/no-network.sb $cmd)
  (cd $res/helper && print -r -- $request | env -i HOME=$HOME PATH=/usr/bin:/bin LANG=en_US.UTF-8 \
    TMPDIR=$tmp XDG_CACHE_HOME=$tmp/cache CUTLINE_MODELS=$models "${cmd[@]}" 2>>$tmp/helper.log || true) | tail -1
}

check() {  # check <name> <json line> <python condition on `r`>
  local name=$1 line=$2 cond=$3
  if $py -c "import json,sys; r=json.loads(sys.argv[1]); sys.exit(0 if ($cond) else 1)" "$line" 2>/dev/null; then
    echo "smoke: $name ok"
  else
    echo "smoke: $name FAILED: $line" >&2
    tail -20 $tmp/helper.log >&2 || true
    exit 1
  fi
}

line=$(job '{"command": "versions"}')
check "runtime ($($py -c 'import json,sys; d=json.loads(sys.argv[1])["data"]; print("python", d["python"], "torch", d["torch"])' "$line" 2>/dev/null || echo ?))" \
  "$line" 'r["type"] == "result"'
line=$(job '{"command": "network_probe"}')
check "network blocked" "$line" 'r["type"] == "result" and r["data"]["blocked"]'

if [[ -z $models ]]; then
  echo "smoke: no models folder given; skipped the analysis check"
  exit 0
fi
# 20 s at 120 BPM: kick drum on every beat, a held chord, and a sung-like vowel tone.
$py - $tmp/song.wav <<'PY'
import sys, numpy as np, soundfile as sf
sr, n = 44100, 44100 * 20
t = np.arange(n) / sr
mix = 0.15 * (np.sin(2*np.pi*220*t) + np.sin(2*np.pi*277*t) + np.sin(2*np.pi*330*t))
voice = 0.2 * np.sin(2*np.pi*440*t + 3*np.sin(2*np.pi*5*t)) * (np.sin(2*np.pi*0.25*t) > 0)
for b in np.arange(0, 20, 0.5):
    i = int(b * sr); k = np.arange(min(4000, n - i))
    mix[i:i+len(k)] += 0.9 * np.sin(2*np.pi*60*k/sr) * np.exp(-k/600)
sf.write(sys.argv[1], np.stack([mix + voice] * 2, 1).astype(np.float32), sr)
PY
start=$SECONDS
line=$(job "{\"command\": \"analyze_audio\", \"args\": {\"audio\": \"$tmp/song.wav\"}, \"output_dir\": \"$tmp/analysis\"}" sandbox)
check "song analysis offline ($(( SECONDS - start )) s)" "$line" 'r["type"] == "result" and abs(r["data"]["duration"] - 20) < 0.1 and len(r["data"]["beats"]) > 10'
start=$SECONDS
line=$(job "{\"command\": \"align_lyrics\", \"args\": {\"vocals\": \"$tmp/analysis/vocals.flac\", \"lines\": [[\"la\", \"la\", \"la\"], [\"la\", \"la\"]], \"language\": \"en\"}, \"output_dir\": \"$tmp/align\"}" sandbox)
check "lyric alignment offline ($(( SECONDS - start )) s)" "$line" 'r["type"] == "result" and [len(l) for l in r["data"]["lines"]] == [3, 2]'
