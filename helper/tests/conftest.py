import json
import os
import subprocess
import sys

import pytest

HELPER_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


TINY_MANIFEST = {"version": 3, "total_bytes": 4, "items": [
    {"id": "w", "label": "Weights", "bytes": 4,
     "files": [{"path": "weights.bin", "url": "https://example.invalid/w", "size": 4, "sha256": "x"}]}]}


@pytest.fixture
def manifest(tmp_path):
    """A pinned manifest with one 4-byte file (stands in for helper/cutline_helper/models.json)."""
    path = tmp_path / "models.json"
    path.write_text(json.dumps(TINY_MANIFEST))
    return path


@pytest.fixture
def models(tmp_path, manifest):
    """A complete models dir for the tiny manifest."""
    d = tmp_path / "models"
    d.mkdir()
    (d / "weights.bin").write_bytes(b"1234")
    (d / ".complete").write_text(json.dumps({"version": 3}))
    return d


@pytest.fixture
def run_helper(models, manifest, tmp_path):
    def run(request, models_dir=None):
        env = {"PATH": "/usr/bin:/bin", "HOME": str(tmp_path), "CUTLINE_MODELS": str(models_dir or models),
               "CUTLINE_MODELS_MANIFEST": str(manifest)}
        line = request if isinstance(request, str) else json.dumps(request)
        p = subprocess.run([sys.executable, "-E", "-s", "-B", "-m", "cutline_helper"], input=line + "\n",
                           capture_output=True, text=True, cwd=HELPER_DIR, env=env, timeout=60)
        messages = [json.loads(l) for l in p.stdout.splitlines() if l.strip()]
        return p.returncode, messages, p.stderr
    return run
