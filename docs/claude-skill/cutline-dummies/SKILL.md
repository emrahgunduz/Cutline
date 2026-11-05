---
name: cutline-dummies
description: Read a music video production document (treatment, concept, shot list or storyboard) and place one Cutline dummy card per scene on the timeline at the scene's exact start and end, through Cutline's control channel. Use when the user wants to put the scenes of a production / concept document into Cutline, block out a video with placeholders, or "generate dummies" from a document. Triggers on: cutline dummies, place dummies, dummies from the document, put the scenes in Cutline, block out the timeline, storyboard to Cutline.
---

# Cutline dummies from a production document

Cutline (the user's music video editor) has a control channel. Talk to it only with `cutline-ctl`; never edit project files on disk. It never changes audio or lyrics; neither do you.

`cutline-ctl` ships inside the app. Use the first that exists:
- `/Volumes/PRO-G40/Code/Cutline/build/Release/Cutline.app/Contents/MacOS/cutline-ctl` (the app the user runs)
- `/Volumes/PRO-G40/Code/Cutline/build/DerivedData/Build/Products/Debug/Cutline.app/Contents/MacOS/cutline-ctl`

Every command prints JSON. Exit 0 = ok, 1 = refused or error (read `message`), 2 = Cutline not running, or several running.

## 1. Read the scenes

Read the whole document. For each scene take:
- `start`, `end`: seconds (numbers). Convert `MM:SS`, `MM:SS.cc`, `H:MM:SS`, `0:12–0:31`, `00:12 - 00:31`, `12s–31s`. A scene with a start but no end ends where the next one starts; the last one ends at the song's end if the document says it, else ask.
- `title`: the scene's own name or number as the document gives it ("Scene 3 — The Rooftop"); short (under ~60 characters). Never invent one; if there is none, leave it empty (Cutline names it Dummy 0001, 0002…).
- `description`: what is seen, in one to three plain sentences (who, where, what happens, the shot), from the document's action/visual text. Not the lyrics, not camera jargon lists.

Documents from the `music-video-concept` skill (`99_final_concept.md`): section "8. Scene-By-Scene Breakdown", one heading per scene, `**Timecode:** start – end (duration)` in `MM:SS.cc`; build the description from **Action** (plus **Location** if it helps). Scenes are contiguous from 00:00.00.

Times in production documents are song times (from the start of the song). Use `time_base: "song"` (Cutline adds where the song starts on its timeline). Use `"timeline"` only if the document says its times are edit/timeline times.

Check before sending: every end is after its start, scenes are in order and don't overlap (if two overlap or there's a gap you can't explain, ask the user). Show the user a compact table (number, start–end, title) and say how many dummies you'll place; then go on without waiting unless something was unclear.

## 2. Connect (the handshake)

1. `cutline-ctl apps`. None: ask the user to open Cutline with the project. Several: ask which (show `pid` and app path), then pass `--pid N` to `hello`.
2. Tell the user: "Cutline will ask you to allow the connection." Then:
   `cutline-ctl hello --client Claude --purpose "Place N dummies from <document name>"` (it waits for the user's answer; give the Bash call a 5-minute timeout).
   `denied`: stop and tell the user. Otherwise keep the printed `session` value (pid:token) for every later command.
3. Projects are in the welcome. One: use it. Several: ask the user which (by name), with AskUserQuestion. Then `cutline-ctl use --session S --project ID`.
4. `cutline-ctl tools --session S`: check `add_dummies` is there and read its arguments (they win over this file if they differ).

## 3. Place the dummies

Write the arguments to a JSON file in your scratchpad (not the user's folders) and send it:

```json
{"scenes": [{"title": "Scene 1 — Dawn", "description": "Empty street at dawn. The singer walks in from the left.", "start": 0, "end": 12.5}],
 "time_base": "song", "replace": true}
```

`cutline-ctl call --session S --tool add_dummies --args-file /path/to/scenes.json`

`replace: true` (default) first removes what an earlier run put on the Dummies track; use `false` only if the user asks to add to the existing dummies. Colors: leave them out (the project's dummy color is used) unless the user asks; then `"color": "#RRGGBB"` per scene.

Then `cutline-ctl call --session S --tool project_info` and check the `dummies` list matches what you sent (count and times). Finally always `cutline-ctl bye --session S`, also after an error.

## 4. Tell the user

How many dummies were placed, on which project, on the "Dummies" video track, from when to when; that it's one undo step in Cutline (Edit > Undo Place Dummies); and any scene you skipped or changed and why. Keep it short.

## Rules

- Only `project_info`, `add_dummies`, `remove_dummies`. Never anything that would touch audio or lyrics.
- Approval is the user's, in Cutline. Never try to get around a denial or a closed session: say hello again only if the user asks.
- Don't keep the session open: bye when done.
