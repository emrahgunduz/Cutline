---
name: cutline-dummies
description: Place one Cutline dummy card per scene of a music video production document (treatment, concept, shot list or storyboard) at the scene's exact start and end, through Cutline's control channel; and the reverse, read the dummies' times back from Cutline after the user re-arranged them and update the document. Use when the user wants to put a document's scenes into Cutline, block out a video with placeholders, "generate dummies", or bring the edited scene timing back into the document. Triggers on: cutline dummies, place dummies, dummies from the document, put the scenes in Cutline, block out the timeline, storyboard to Cutline, update the document from Cutline, read the dummies back, sync scene times from Cutline.
---

# Cutline dummies from a production document

Cutline (the user's music video editor) has a control channel. Talk to it only with `cutline-ctl`; never edit project files on disk. It never changes audio or lyrics; neither do you.

`cutline-ctl` ships inside the app. Whenever Cutline opens, it links its own copy to one fixed place, wherever the app is installed:

```bash
"$HOME/Library/Application Support/Cutline/cutline-ctl" apps
```

Below, `cutline-ctl` means that path. Always quote it (it has a space). If it isn't there, Cutline hasn't been opened yet (or is too old to make the link): ask the user to open Cutline, then try again. Never look for the app in the user's folders.

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
4. `cutline-ctl tools --session S`: check the tools below are there and read their arguments (they win over this file if they differ).

## 3. Choose the track

`cutline-ctl call --session S --tool list_video_tracks` lists every video track (index 0 = bottom layer; the highest index is drawn on top) with its id, name, hidden flag, and items (name, kind video/image/dummy, start, end in timeline seconds).

- The user named a track ("put them on Video 3", "on the Storyboard track"): use it (by its `id`).
- Otherwise: a track whose items are all dummies and that the user hasn't said to keep (usually "Dummies") can be reused with `replace: true`. If none fits, or the scenes would land on videos or images, create one: `cutline-ctl call --session S --tool create_video_track --args '{"name": "<short document name>", "position": "top"}'` and use the `id` it returns.
- Never put dummies where they'd overlap a video or image: Cutline refuses the whole call ("overlaps …"), changes nothing, and tells you what is in the way; then pick another track or create one.
- Tracks can't be deleted (there is no tool for it); don't create more than you need.

## 4. Place the dummies

Write the arguments to a JSON file in your scratchpad (not the user's folders) and send it:

```json
{"scenes": [{"title": "Scene 1 — Dawn", "description": "Empty street at dawn. The singer walks in from the left.", "start": 0, "end": 12.5}],
 "track": "<track id>", "time_base": "song", "replace": true}
```

`cutline-ctl call --session S --tool add_dummies --args-file /path/to/scenes.json`

Leave `track` out to use the track named "Dummies" (made on top if missing). `replace: true` (default) first removes the dummies already on that track (only dummies; videos and images stay); use `false` only to add to them. Colors: leave them out (the project's dummy color is used) unless the user asks; then `"color": "#RRGGBB"` per scene.

Then `list_video_tracks` again and check the track's dummies match what you sent (count and times). Finally always `cutline-ctl bye --session S`, also after an error.

## 5. Tell the user

How many dummies were placed, on which project and track (and whether you created it), from when to when; that it's one undo step in Cutline (Edit > Undo Place Dummies); and any scene you skipped or changed and why. Keep it short.

## Reading the timing back into the document

When the user has re-arranged the dummies in Cutline (moved, trimmed, cut, deleted, reordered) and wants the document to match:

1. Connect as in step 2 (hello, use). `project_info` gives `song_start`.
2. `list_video_tracks`; take the dummy items (`kind: "dummy"`) of the track the scenes are on (the one you or the user chose; if unsure, ask). Each has `name` (its title), `description`, `start`, `end` in timeline seconds, and `dummy_id`.
3. Convert to song time: `song time = timeline time − song_start` (the document's times are song times), and write them in the document's own format (e.g. `MM:SS.cc`, with the duration in seconds if the document shows it).
4. Match each dummy to its scene by title first, then by description. Sort by start: that is the new scene order.
   - Two items with the same `dummy_id`: the user cut one scene into two. Ask whether to split the scene in the document or keep it as one.
   - A scene with no dummy left: the user removed it. Ask before deleting it from the document.
   - A dummy that matches no scene: ask what it is.
5. Before editing, show the user a compact before/after table (scene, old start–end, new start–end) of only what changed. Then update the document: times and durations, scene order; keep everything else as it is (don't rewrite the scene text). If the document requires contiguous scenes (like `music-video-concept`'s "contiguous from 00:00.00"), point out any gaps or overlaps the new timing has instead of silently fixing them.
6. `bye`. The dummy cards still show their original length in their bottom-right corner; that's fine (a fresh add_dummies run would redraw them).

## Rules

- Only the tools Cutline lists (`project_info`, `list_video_tracks`, `create_video_track`, `add_dummies`, `remove_dummies`). They never touch audio or lyrics, and nothing deletes a track.
- Approval is the user's, in Cutline. Never try to get around a denial or a closed session: say hello again only if the user asks.
- Don't keep the session open: bye when done.
