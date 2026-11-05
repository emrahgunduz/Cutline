"""Download the pinned models (helper/cutline_helper/models.json) into a folder, for
development and tests. The app does the same download itself (ModelDownloader).

    python3 scripts/fetch_models.py build/ml/models

Resumes partial files (curl -C -), verifies every SHA-256, and writes `.complete` last.
"""
import os
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "helper"))
from cutline_helper.models import COMPLETE, expected_files, load_manifest, sha256, status, write_complete  # noqa: E402

root = os.path.abspath(sys.argv[1])
manifest = load_manifest()
try:
    os.remove(os.path.join(root, COMPLETE))
except FileNotFoundError:
    pass
for f in expected_files(manifest):
    dst = os.path.join(root, f["path"])
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    if not (os.path.exists(dst) and os.path.getsize(dst) == f["size"]):
        print(f"==> {f['path']} ({f['size'] / 1e6:.0f} MB)", flush=True)
        part = dst + ".part"
        subprocess.run(["curl", "-fL", "--retry", "3", "-C", "-", "-o", part, f["url"]], check=True)
        os.replace(part, dst)
    if sha256(dst) != f["sha256"]:
        os.remove(dst)
        sys.exit(f"checksum mismatch for {f['path']}; deleted, run again")
write_complete(root, manifest)
print(status(root, manifest))
