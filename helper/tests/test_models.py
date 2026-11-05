import json
import os
import subprocess
import sys

from cutline_helper import models as m

from conftest import HELPER_DIR, TINY_MANIFEST


def test_status_rules(tmp_path):
    d = tmp_path / "m"
    d.mkdir()
    assert m.status(str(d), TINY_MANIFEST)["state"] == "missing"
    (d / "weights.bin").write_bytes(b"12")  # wrong size: doesn't count
    assert m.status(str(d), TINY_MANIFEST) == {"state": "missing", "have_bytes": 0, "part_bytes": 0, "total_bytes": 4, "version": 3}
    (d / "weights.bin.part").write_bytes(b"12")
    assert m.status(str(d), TINY_MANIFEST)["part_bytes"] == 2
    assert m.status(str(d), TINY_MANIFEST)["state"] == "partial"  # a started download
    (d / "weights.bin.part").unlink()
    (d / "weights.bin").write_bytes(b"1234")
    assert m.status(str(d), TINY_MANIFEST)["state"] == "partial"  # every byte, but no marker
    m.write_complete(str(d), TINY_MANIFEST)
    assert m.status(str(d), TINY_MANIFEST)["state"] == "ready"
    (d / ".complete").write_text(json.dumps({"version": 2}))  # an older model set
    assert m.status(str(d), TINY_MANIFEST)["state"] == "partial"
    assert m.missing_files(str(d), TINY_MANIFEST) == []


def test_check_models_command(models, manifest):
    p = subprocess.run([sys.executable, "-E", "-s", "-B", "-m", "cutline_helper", "--check-models", str(models)],
                       capture_output=True, text=True, cwd=HELPER_DIR,
                       env={"PATH": "/usr/bin:/bin", "CUTLINE_MODELS_MANIFEST": str(manifest)}, timeout=60)
    assert p.returncode == 0
    assert json.loads(p.stdout) == {"type": "models_status", "state": "ready", "have_bytes": 4, "part_bytes": 0, "total_bytes": 4, "version": 3}


def test_pinned_manifest_is_consistent():
    man = m.load_manifest(m.MANIFEST)
    files = m.expected_files(man)
    assert man["total_bytes"] == sum(i["bytes"] for i in man["items"]) == sum(f["size"] for f in files)
    for item in man["items"]:
        assert item["bytes"] == sum(f["size"] for f in item["files"])
    for f in files:
        assert f["url"].startswith("https://") and len(f["sha256"]) == 64
        assert not os.path.isabs(f["path"]) and ".." not in f["path"]
    # The helper loads these exact paths.
    paths = {f["path"] for f in files}
    assert "whisper-medium/model.bin" in paths
    assert "torch/hub/checkpoints/beat_this-final0.ckpt" in paths
