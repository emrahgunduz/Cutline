import json
import os
import subprocess
import sys

import pytest

HELPER_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


@pytest.fixture
def models(tmp_path):
    """A models dir with one tiny file and a manifest that lists it."""
    d = tmp_path / "models"
    d.mkdir()
    (d / "weights.bin").write_bytes(b"1234")
    (d / "manifest.json").write_text(json.dumps({"version": 1, "files": [{"path": "weights.bin", "size": 4}]}))
    return d


@pytest.fixture
def run_helper(models, tmp_path):
    def run(request, models_dir=None):
        env = {"PATH": "/usr/bin:/bin", "HOME": str(tmp_path), "CUTLINE_MODELS": str(models_dir or models)}
        line = request if isinstance(request, str) else json.dumps(request)
        p = subprocess.run([sys.executable, "-E", "-s", "-B", "-m", "cutline_helper"], input=line + "\n",
                           capture_output=True, text=True, cwd=HELPER_DIR, env=env, timeout=60)
        messages = [json.loads(l) for l in p.stdout.splitlines() if l.strip()]
        return p.returncode, messages, p.stderr
    return run
