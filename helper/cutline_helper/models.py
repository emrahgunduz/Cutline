"""The pinned model set (models.json, next to this file) and what a models folder holds.

The app downloads the models into a folder the user picks (or Application Support) and
passes it as CUTLINE_MODELS. The same rules are in the app's ModelFolderStatus.check():
a file counts only when its size matches (`.part` files count as a started download); the
folder is "ready" when every byte is there and `.complete` names the manifest's version.
"""
import hashlib
import json
import os

MANIFEST = os.path.join(os.path.dirname(os.path.abspath(__file__)), "models.json")
COMPLETE = ".complete"


def load_manifest(path: str | None = None) -> dict:
    with open(path or os.environ.get("CUTLINE_MODELS_MANIFEST") or MANIFEST, encoding="utf-8") as f:
        return json.load(f)


def expected_files(manifest: dict) -> list[dict]:
    return [f for item in manifest["items"] for f in item["files"]]


def _size(path: str) -> int | None:
    try:
        return os.path.getsize(path)
    except OSError:
        return None


def missing_files(models_dir: str, manifest: dict | None = None) -> list[str]:
    """Paths (relative to models_dir) that are absent or the wrong size."""
    manifest = manifest or load_manifest()
    return [f["path"] for f in expected_files(manifest) if _size(os.path.join(models_dir, f["path"])) != f["size"]]


def installed_version(models_dir: str) -> int | None:
    try:
        with open(os.path.join(models_dir, COMPLETE), encoding="utf-8") as f:
            return json.load(f).get("version")
    except (OSError, ValueError, AttributeError):
        return None


def status(models_dir: str, manifest: dict | None = None) -> dict:
    manifest = manifest or load_manifest()
    have = part = 0
    for f in expected_files(manifest):
        path = os.path.join(models_dir, f["path"])
        if _size(path) == f["size"]:
            have += f["size"]
        else:
            part += min(_size(path + ".part") or 0, f["size"])  # a download continues from these
    total = manifest["total_bytes"]
    marker = os.path.exists(os.path.join(models_dir, COMPLETE))
    if have == total and installed_version(models_dir) == manifest["version"]:
        state = "ready"
    elif have == 0 and part == 0 and not marker:
        state = "missing"
    else:
        state = "partial"
    return {"state": state, "have_bytes": have, "part_bytes": part, "total_bytes": total, "version": manifest["version"]}


def sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(8 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def write_complete(models_dir: str, manifest: dict | None = None) -> None:
    """Marks the folder complete. Call only after every file is in place and verified."""
    import datetime
    manifest = manifest or load_manifest()
    with open(os.path.join(models_dir, COMPLETE), "w", encoding="utf-8") as f:
        json.dump({"version": manifest["version"], "installed": datetime.datetime.now().isoformat(timespec="seconds")}, f)
