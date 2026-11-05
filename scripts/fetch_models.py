"""Download every model the helper needs into build/ml/models (run by build_python_runtime.sh
with the bundled interpreter). Nothing is fetched at app runtime."""
import os
import sys

models = os.path.abspath(sys.argv[1])
os.environ["TORCH_HOME"] = os.path.join(models, "torch")
os.environ["HF_HOME"] = os.path.join(models, "hf")
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "helper"))


def step(name):
    print(f"==> {name}", flush=True)


step("HTDemucs (vocal stem)")
from demucs.pretrained import get_model
get_model("htdemucs")

step("Beat This! (beats and downbeats)")
from beat_this.inference import load_checkpoint
load_checkpoint("final0", device="cpu")

step("MMS forced aligner")
import torchaudio
torchaudio.pipelines.MMS_FA.get_model()
torchaudio.pipelines.MMS_FA.get_dict()

step("faster-whisper medium")
from huggingface_hub import snapshot_download
snapshot_download("Systran/faster-whisper-medium", local_dir=os.path.join(models, "whisper-medium"))

# huggingface_hub leaves lock and metadata folders next to downloads; they are not needed.
import shutil
for junk in [os.path.join(models, "whisper-medium", ".cache"), os.path.join(models, "hf")]:
    shutil.rmtree(junk, ignore_errors=True)

from cutline_helper.models import write_manifest
m = write_manifest(models)
total = sum(f["size"] for f in m["files"])
print(f"==> manifest: {len(m['files'])} files, {total / 1e9:.2f} GB")
