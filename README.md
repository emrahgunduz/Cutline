# Cutline

A simple native macOS (Apple Silicon) editor for music videos, portrait social videos and portrait ads.

## Folders

| Folder | What's in it |
|---|---|
| `Cutline/App` | App start, menus, the project document, the main window and its toolbar and status bar |
| `Cutline/Assets` | Assets panel, importing, thumbnails, waveforms, proxies |
| `Cutline/Preview` | The live preview and the player behind it |
| `Cutline/Timeline` | Timeline view, layout, snapping, lyric correction |
| `Cutline/Inspector` | Right-hand inspector (clips, lyrics, shortcuts) |
| `Cutline/Model` | The project data model and editing commands |
| `Cutline/Render` | Compositor, frame and lyric rendering, render cache keys |
| `Cutline/Export` | Export, size estimate and the size-target solver |
| `Cutline/Analysis` | Runs the Python helper (song analysis, lyric alignment) |
| `Cutline/Analysis/Models` | The analysis models: manifest, folder state, download, the New Project card |
| `Cutline/Control` | The control channel (local socket that Claude uses, with your approval) |
| `Cutline/Dialogs` | New Project, New Dummy, Export and Reset Caches |
| `Cutline/Settings` | The Settings window: Presets and Models tabs |
| `Cutline/Resources` | Bundled presets, platform overlays, document icon |
| `CutlineTests` | Unit and integration tests |
| `Tools/cutline-ctl` | Command-line client for the control channel (shipped inside the app) |
| `helper` | The offline Python helper (`cutline_helper`), its pinned requirements, models list and tests |
| `scripts` | Build scripts (runtime, Release, version stamp, icons, model fetch) |
| `docs` | Glossary, the plan, and the Claude skill |

`build/` and `Example_Music_Video/` aren't tracked. `build/ml` holds the Python runtime (copied into the app) and a development copy of the models. `build/Release/Cutline.app` is the Release app.

## Building

```bash
scripts/build_python_runtime.sh   # once: Python runtime into build/ml (and models into build/ml/models)
xcodegen generate                 # after adding or moving files
scripts/build_release.sh          # Release app into build/Release/Cutline.app
```

The models aren't in the app. Cutline downloads them from the New Project window or Settings > Models (see `docs/GLOSSARY.md`, "Analysis models").

Helper tests:

```bash
PYTHONPATH=build/ml-dev build/ml/python/bin/python3 -B -m pytest -c helper/pytest.ini --rootdir helper helper/tests
```
