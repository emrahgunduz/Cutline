"""The model manifest written at build time, checked before every job."""
import json
import os

MANIFEST = "manifest.json"


def default_models_dir() -> str:
    # Bundle layout: Resources/ml/{helper/cutline_helper, models}
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(here, "..", "..", "models"))


def missing_files(models_dir: str) -> list[str]:
    """Paths (relative to models_dir) that the manifest lists but are absent or the wrong size."""
    manifest_path = os.path.join(models_dir, MANIFEST)
    try:
        with open(manifest_path, encoding="utf-8") as f:
            manifest = json.load(f)
    except (OSError, ValueError):
        return [MANIFEST]
    missing = []
    for entry in manifest.get("files", []):
        path = os.path.join(models_dir, entry["path"])
        try:
            if os.path.getsize(path) != entry["size"]:
                missing.append(entry["path"])
        except OSError:
            missing.append(entry["path"])
    return missing


def write_manifest(models_dir: str) -> dict:
    files = []
    for root, _dirs, names in os.walk(models_dir):
        for name in sorted(names):
            if name == MANIFEST or name.startswith("."):
                continue
            full = os.path.join(root, name)
            files.append({"path": os.path.relpath(full, models_dir), "size": os.path.getsize(full)})
    files.sort(key=lambda e: e["path"])
    manifest = {"version": 1, "files": files}
    with open(os.path.join(models_dir, MANIFEST), "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=1)
    return manifest
