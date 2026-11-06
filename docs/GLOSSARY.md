# Cutline Glossary

Shared names for the parts of Cutline. Update this file when a feature adds or renames something.

## Window

| Term | What it is |
|---|---|
| **Toolbar** | Strip at the very top: Import, Undo, Redo, Split, Delete, Video Track, Lyrics Track, Clear Cache, Reset Caches, Export. |
| **Assets panel** | Left column with your imported files. |
| **Preview** | Middle area: the video canvas plus the transport bar below it. |
| **Inspector** | Right column. Shows the selected item's settings, or the shortcuts list when nothing is selected. |
| **Timeline** | Bottom area with the tracks. |
| **Divider** | Draggable line between two panels. Panel sizes are saved per project when you drag a divider; resizing the window only changes the preview, and each project keeps its own panel sizes and window frame. |
| **Status bar** | Bottom strip of the window: selection details, project length vs. limit, estimated size, format, save state, render cache size, and Disconnect while a program uses the control channel. |
| **New Project window** | Shown at launch and by File > New Project… (⌘N): pick the project type and resolution, then Create Project, Open…, Import from Project… or a recent project. While the analysis models are missing it shows the **models card** at the top and none of these work. |
| **Models card** | The top of the New Project window until the models are ready: Download (to Library) or Choose Folder…, live progress with speed and time left, Cancel to pause, Resume Download, and "Models folder not found" when a chosen disk isn't connected. |
| **Settings** | Cutline > Settings… (⌘,), with two tabs: **Presets** (format presets) and **Models** (see **Settings > Models**). |

## Assets panel

| Term | What it is |
|---|---|
| **Asset** | One imported file (video, image, audio or lyrics TXT). |
| **Tile** | One asset's thumbnail card. |
| **Group / section** | Videos, Images, Dummies, Audio and Lyrics, each collapsible. |
| **Used mark** | Green check on an asset that is on the timeline. |
| **Proxy badge** | Orange "PROXY 1/4" label. |
| **Footer** | The "3 of 9 selected" line at the bottom. |

## Preview

| Term | What it is |
|---|---|
| **Canvas** | The black frame at project size (for example 1920×1080). This is what gets exported. |
| **Viewport zoom / pan** | How close you look at the canvas. It doesn't change the video. |
| **Center button** | Recenters the canvas without changing zoom (Fit also resets zoom). |
| **Selection outline / handles** | Blue box and corner dots on the selected clip. Drag inside to move it; drag a corner to scale it. |
| **Transport bar** | Bar under the canvas: start, −1 frame, play/pause, +1 frame, end, timecode, zoom controls. |
| **Timecode** | `mm:ss:ff` (minutes:seconds:frames). |

## Timeline

| Term | What it is |
|---|---|
| **Button bar** | Icon row at the top of the timeline: Dummy, add tracks, split, delete, snapping and snap groups, cinemascope, Analyze Song, Align Lyrics, zoom. |
| **Ruler** | Time scale under the button bar. Click or drag it to move the playhead. |
| **Playhead** | Red vertical line marking the current time. |
| **Track / row** | One horizontal lane: **Audio**, **Lyrics 1…n**, **Video 1…n**. Video n is drawn on top of lower video tracks. |
| **Track header** | Left part of a row: name, + and −, the ≡ reorder handle, and the resize grip on its bottom edge. |
| **Clip** | A video or image placed on a video track. |
| **Edge / trim** | A clip's left or right end. Dragging an edge changes its start or end. |
| **Split** | Cutting a clip in two at the playhead (⌘B). |
| **Filmstrip** | Frame thumbnails inside a clip. |
| **Waveform** | The audio drawing on the Audio track. |
| **Line** | One lyric line, the darker purple box. |
| **Word** | One word inside a line, the light purple box on the word rows. |
| **Snapping / snap guide** | Edges pulling toward nearby edges or the playhead, shown with a yellow line. Toggle with S; hold ⌘ to bypass. |
| **Project end** | Darker area after the last clip or audio. |
| **Scroller** | The horizontal scrollbar just under the button bar (vertical one on the right). |
| **Word rows** | The rows under a lyric line, one per word (word 1 on row 1, …). |
| **Name bar** | The darker strip on top of a clip or lyric line showing its name. |
| **Edit point** | Any clip, line, audio or cinemascope edge; ↑/↓ jump between them. |
| **Multi-selection** | Several items selected with ⌘-click or a **selection box** (⇧-drag on empty space). |
| **Cinemascope markers** | Two orange flags on the ruler: bars start closing at the first, frame is fully 2.35:1 from the second. |

## Project concepts

| Term | What it is |
|---|---|
| **Project type** | Music video, Portrait social or Portrait ad. Each has its own size, length limit and codec. |
| **Transform** | A clip's scale and X/Y position. |
| **Flip horizontal** | Clip inspector > Size & Position: mirrors a video or image left to right in place (same position and size). Not offered for dummies. |
| **Filter** | A per-clip effect (Color, Fade) with an on/off switch. |
| **Placement** | Inspector section for lyric lines: align left/center/right, top/middle/bottom with **padding**; several lines stack with a **line gap**. **Auto Position** returns a line to the automatic stack. |
| **Animation** | Lyric inspector section: fade in / fade out times for all words, Whole word or **Letter by letter** (letters fade in turn within the fade time, with **Overlap**). |
| **Shadow strength** | How dense the lyric drop shadow is (100% = the color's own opacity). |
| **Lyric style** | The one font, size, color, position and drop shadow used for all lyrics. |
| **Proxy** | A smaller copy of a video used only for preview. Export always uses the original. |
| **Alignment** | Matching each lyric word to when it's sung, from the TXT and the vocal stem. Runs after you drop the TXT on a lyrics track (when the song is on the timeline), or from Lyrics > Align Words to Song (⌥⌘L). |
| **Cinemascope / letterbox** | Animated black bars from 16:9 to 2.35:1, music videos only. Toggle in the timeline button bar. |
| **Constant quality vs target bitrate** | The two export rate modes: fixed look with variable size, or fixed size with variable look. |
| **Analysis helper** | The bundled, offline Python process (inside `Cutline.app/Contents/Resources/ml`) that runs the music and lyric models. Built by `scripts/build_python_runtime.sh`. It has no network access; the models it uses are not in the app (see **Analysis models**). |
| **Analysis models** | HTDemucs, Beat This!, the MMS aligner and Whisper medium (about 3 GB), pinned in `helper/cutline_helper/models.json` (URL, size, SHA-256). Downloaded once, from the New Project window or Settings > Models, into `~/Library/Application Support/Cutline/models` or a "Cutline Models" folder you choose (a folder that already has them is used without downloading). Downloads resume after Cancel, are checked against their checksums, and `.complete` is written last. Until the models are ready, no project can be created or opened: opening one (for example by double-clicking it) shows New Project with the download and adds the project to Recent Projects. |
| **Settings > Models** | Where the models are and their status: Show in Finder, Move To…, Use Existing Folder…, Download / Re-download, Move to Trash… and Use Library Folder. |
| **Job** | One run of the analysis helper (for example separating the vocal stem). Shows progress, can be cancelled, and leaves nothing behind if it fails. |
| **Section lane** | The colored strip along the top of the audio row: song sections (A, B, C…) found by analysis. Drag a white boundary to move it, double-click the lane to add one, right-click to remove one. |
| **Beat ticks / downbeats** | Marks along the bottom of the audio row: short ticks for beats, tall ticks for downbeats (the first beat of each bar). Drag a downbeat to correct it. |
| **Loudness curve** | The yellow lines in the audio row: the song's loudness over time (smoothed over ~2 s), mirrored around the centre and scaled so its loudest moment fills the row. The dashed orange lines are the loud level and the dashed blue lines the quiet level (set from the song's median loudness). Where the curve stays past the orange lines for 2 s or more the stretch is marked LOUD (orange tint, bar and tag); inside the blue lines, QUIET (blue). The waveform itself is scaled so its highest peak just fits the row. |
| **Vocal stem** | The song's vocals on their own, separated once by analysis and kept in the project's `analysis/` folder. |
| **Beat and section fixes** | Your corrections to downbeats and sections. Saved in the project, separate from the raw analysis; reset from the audio row's right-click menu. |
| **Snap groups** | The four toggles next to the snapping button: Sections, Downbeats, Beats, and Edges & Playhead. When several targets are in reach, sections win, then downbeats, then beats, then edges. Saved per project. |
| **Beat anchor** | Cinemascope markers placed on (or near) a beat remember it, so they move when that downbeat is corrected or the song is moved. |
| **Unsure word** | A lyric word whose timing confidence is below 60% and that you haven't confirmed. Drawn with an orange outline and bar on the timeline. |
| **Confirmed word** | A word you've checked (Return on an unsure word, tap mode, or dragging it); re-aligning asks whether to keep its time. |
| **Hand-edited word** | A word whose time you changed by dragging its line, a line edge or a group on the timeline. Re-aligning lists confirmed and hand-edited words and asks: Keep My Changes (keeps their times, fits the rest between them) or Re-time All (clears them). |
| **Lead-out** | Lyric inspector > Animation: aligned lines stay on screen this much longer after their last word (default 0 s), never into the next line on the same track. |
| **Lead-in** | Lyric inspector > Animation: aligned words appear this much before they are sung (default 0.15 s). Changing it moves aligned words live; confirmed and hand-placed words stay put. |
| **Next unsure word** | N (⇧N back): selects the next unsure, unconfirmed word in sung order and loops the song around it (±1.75 s, yellow band on the ruler). Return confirms it; Esc stops the loop. |
| **Tap mode** | T: plays from 5 s before the selected word; each Space sets the current word's start to that moment, confirms it, and moves to the next word sung (any track). 1/2/3 play at 100/75/50% with pitch kept. After the last word the song plays 5 s more, then pauses. Esc ends. |
| **Anchor stretch** | Tap mode: confirmed words are anchors, and unconfirmed words between two anchors are re-timed in proportion to fit between them. Dragging a word on the timeline changes only that word. |
| **Sung order** | The order of the lyrics file: each line remembers its place in the TXT it came from, so alignment, tapping, next unsure word and anchor stretch sing the lines in that order wherever you move them (any track, any time). Lines from different files interleave by time; lines from no file go by time. Older projects recover the order by matching lines to the TXT. |
| **Word timing** | New or aligned words start on their own time and end with their line; each word's end can then be changed on its own. Dragging a line's start moves every word's start with it (ends stay); dragging its end moves every word's end with it (starts stay). |
| **Recent Projects** | The last 10 projects you opened or saved, listed in the New Project window. Click one to open it; Clear forgets the list (the projects stay). A project opened while the models are missing is added here, to open once they're downloaded. |
| **Lyrics Language** | Lyrics > Lyrics Language, or the menu that opens from the Align Lyrics button: "Detect from Lyrics" (reads your TXT) or any of the 100 languages Whisper knows, saved per project. It only steers the double-check of unsure words. |
| **Platform UI zones** | Portrait projects: the Platform UI menu in the preview bar shows where TikTok, Reels and Shorts draw their buttons and captions (preview only, never exported). Automatically placed lyrics always stay clear of every platform's zones, so showing or hiding them moves nothing; zones live in platform_overlays.json. |
| **Hard-out line** | Social and ad projects: the red LIMIT line on the timeline at the type's maximum length; anything past it is hatched red as over. **Trim to Limit** (timeline bar, shown when over) ends the project on the last downbeat or lyric-line end before the limit. |
| **Target size** | Export rate mode for social and ads: give a maximum size in MB; Cutline picks the bitrate, checks the finished file and re-encodes automatically (up to twice) if it came out too big. |
| **Budget bar** | Status bar: project length against the limit, and the size target (or the estimated size at the saved bitrate) against it. |
| **Format presets** | Settings > Presets: each project type's length limit, codec, default bitrate and default size target. |
| **Render cache** | Preview frames (in memory) and export segments (2 s pieces in the project's `cache/segments/`), keyed by everything that changes their pixels. A re-export encodes only the segments an edit changed; a cancelled export keeps the finished ones. |
| **Cache strip** | The thin line along the bottom of the ruler: green where the export segment is cached, orange where an edit or setting change made it stale. |
| **Clear Cache** | Toolbar (shows the size), the status bar (size, trash button) or File > Clear Render Cache: empties the render cache. Proxies, thumbnails, waveforms and analysis are kept. |
| **Reset Media Caches** | Toolbar Reset Caches, the status bar (circular-arrows button) or File > Reset Media Caches…: pick thumbnails & waveforms, music analysis and/or proxies to delete and rebuild (proxies: rebuild at their current scale, or remove them). Proxy tiles show a spinner while they rebuild; opening it again while it runs offers to stop. |
| **Import from Project** | New Project window: pick the type and resolution, then a project to copy from. The song, lyric timing, clips and track layout come over once (with the analysis, thumbnails, waveforms and proxies, so nothing re-runs); clips are centred on the new canvas at the same scale, lyric lines go back to automatic placement, and cinemascope is kept only for music videos. Nothing stays linked. |
| **Line spacing** | Lines on one lyric track never overlap (put lines meant to be on screen together on different tracks). A dragged line stops against its neighbour and jumps past it once the pointer is closer to the other side; edges and words stop at the neighbours. |
| **Group drag** | Dragging several selected items: the earliest one snaps, the rest keep their distance from it. |
| **Fill / Fit** | Clip inspector > Size & Position: Fill scales the clip to cover the whole frame (centred, overflow cropped); Fit shows the whole picture. New video clips start filled in every project type; images start fitted. |
| **Nudge** | After clicking the preview or the inspector, the arrow keys move the selected clip or lyric lines 1 px; with ⇧ they move by the step in the inspector's Nudge section (default 10 px, one app-wide setting). ⇧ while dragging in the preview keeps the move to one axis. |
| **Placement padding** | Lyric inspector > Placement: Padding ↔ (left/right) and Padding ↕ (top/bottom), measured from the full frame edges to the letters themselves (never from the cinemascope bars). Align buttons use them; several selected lines align as one block, each line with the same left or right letter edge. |
| **Line Layout** | Lyric inspector, top panel, per lyric line (applies to every selected line): **Auto width** = one line as wide as the text (it can be wider than the frame); **Auto height** = wraps at the Width (0 px up, no upper limit; type values beyond the slider) and is as tall as its rows; **Text align** left/center/right. Lyrics are never scaled to fit. New lines default to Auto width, left. |
| **Line anchor** | A positioned lyric line's x is its anchor: the box's left edge for left-aligned text, its middle for centred, its right edge for right-aligned, so the text grows away from it. Changing the alignment keeps the box in place. Lines positioned in older projects became centred so they didn't move. |
| **Mute / show-hide** | Track headers: the speaker button mutes the song, the eye button hides a video or lyrics track. Muted or hidden tracks turn orange in the header and dim on the timeline, and are left out of the preview and the export (the export sheet lists them). Hidden tracks still count for the project length, and hidden lyrics are still aligned. |
| **Dummy** | A placeholder card for a shot that doesn't exist yet: the Dummy button (first in the timeline bar) opens New Dummy (title, scene description, font, length, color, with a live preview; ⌘↩ adds) and puts the card in the assets' Dummies section. It is an image Cutline draws at the project's size (no file): the color fills the frame, the title is at the top left, the description wraps under it across the frame, and the length is at the bottom right, all 100 px from the edges in HD (scaled with the frame); in a music video with cinemascope on, the top and bottom paddings start at the 2.35:1 bars, so nothing is hidden under them. An empty title is named Dummy 0001, 0002 ... The sheet remembers font, title, length and color per project; the description is per card. Dropped on the timeline, a dummy lasts its length. |
| **Control channel** | Lets a program on this Mac (Claude, via `cutline-ctl` inside the app; each time Cutline opens it links that client to `~/Library/Application Support/Cutline/cutline-ctl`, so it's found wherever the app is installed) use Cutline with your approval: it says hello, Cutline asks you (Allow / Don't Allow), and only then sees the open projects, picks one, lists the tools (project_info, list_video_tracks, create_video_track, add_dummies, remove_dummies; tracks can be created, never deleted; dummies never overlap or replace videos and images) and calls them. Approval lasts until it says bye, 15 minutes of silence, or Disconnect in the status bar; it is never remembered. A Unix socket only your user can open (~/Library/Application Support/Cutline/control). Audio and lyrics are never changed. The `cutline-dummies` Claude skill (docs/claude-skill) places one dummy per scene of a production document on the Dummies track. |
