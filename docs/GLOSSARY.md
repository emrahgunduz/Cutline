# Cutline Glossary

Shared names for the parts of Cutline. Update this file when a feature adds or renames something.

## Window

| Term | What it is |
|---|---|
| **Toolbar** | Strip at the very top: Import, Undo/Redo, Split, Delete, Video Track, Lyrics Track, project format, Export. |
| **Assets panel** | Left column with your imported files. |
| **Preview** | Middle area: the video canvas plus the transport bar below it. |
| **Inspector** | Right column. Shows the selected item's settings, or the shortcuts list when nothing is selected. |
| **Timeline** | Bottom area with the tracks. |
| **Divider** | Draggable line between two panels. Panel sizes are saved per project. |
| **Status bar** | Bottom strip of the window: selection details, project length vs. limit, format, proxies in use, save state. |

## Assets panel

| Term | What it is |
|---|---|
| **Asset** | One imported file (video, image, audio or lyrics TXT). |
| **Tile** | One asset's thumbnail card. |
| **Group / section** | Videos, Images, Audio and Lyrics, each collapsible. |
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
| **Button bar** | Small icon row at the top of the timeline (add tracks, split, delete, snapping, zoom). |
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
| **Snapping / snap guide** | Edges pulling toward nearby edges or the playhead, shown with a yellow line. Toggle with N; hold ⌘ to bypass. |
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
| **Filter** | A per-clip effect (Color, Fade) with an on/off switch. |
| **Placement** | Inspector section for lyric lines: align left/center/right, top/middle/bottom with **padding**; several lines stack with a **line gap**. **Auto Position** returns a line to the automatic stack. |
| **Animation** | Lyric inspector section: fade in / fade out times for all words, Whole word or **Letter by letter** (letters fade in turn within the fade time, with **Overlap**). |
| **Shadow strength** | How dense the lyric drop shadow is (100% = the color's own opacity). |
| **Lyric style** | The one font, size, color, position and drop shadow used for all lyrics. |
| **Proxy** | A smaller copy of a video used only for preview. Export always uses the original. |
| **Alignment** | Matching each lyric word to when it's sung, from the TXT and the vocal stem. Runs after you drop the TXT on a lyrics track (when the song is on the timeline), or from Lyrics > Align Words to Song (⌥⌘L). |
| **Cinemascope / letterbox** | Animated black bars from 16:9 to 2.35:1, music videos only. Toggle in the timeline button bar. |
| **Constant quality vs target bitrate** | The two export rate modes: fixed look with variable size, or fixed size with variable look. |
| **Analysis helper** | The bundled, offline Python process (inside `Cutline.app/Contents/Resources/ml`) that runs the music and lyric models. Built by `scripts/build_python_runtime.sh`. |
| **Job** | One run of the analysis helper (for example separating the vocal stem). Shows progress, can be cancelled, and leaves nothing behind if it fails. |
| **Section lane** | The colored strip along the top of the audio row: song sections (A, B, C…) found by analysis. Drag a white boundary to move it, double-click the lane to add one, right-click to remove one. |
| **Beat ticks / downbeats** | Marks along the bottom of the audio row: short ticks for beats, tall ticks for downbeats (the first beat of each bar). Drag a downbeat to correct it. |
| **Loud / quiet shading** | Orange tint over loud stretches of the song and dark tint over quiet ones. |
| **Vocal stem** | The song's vocals on their own, separated once by analysis and kept in the project's `analysis/` folder. |
| **Beat and section fixes** | Your corrections to downbeats and sections. Saved in the project, separate from the raw analysis; reset from the audio row's right-click menu. |
| **Snap groups** | The four toggles next to the snapping button: Sections, Downbeats, Beats, and Edges & Playhead. When several targets are in reach, sections win, then downbeats, then beats, then edges. Saved per project. |
| **Beat anchor** | Cinemascope markers placed on (or near) a beat remember it, so they move when that downbeat is corrected or the song is moved. |
| **Unsure word** | A lyric word whose timing confidence is below 60% and that you haven't confirmed. Drawn with an orange outline and bar on the timeline. |
| **Confirmed word** | A word you've checked; alignment asks whether to keep its time. |
| **Lead-in** | Lyric inspector > Animation: aligned words appear this much before they are sung (default 0.15 s). Changing it moves aligned words live; confirmed and hand-placed words stay put. |
| **Next unsure word** | N (⇧N back): selects the next unsure, unconfirmed word in sung order and loops the song around it (±1.75 s, yellow band on the ruler). Return confirms it; Esc stops the loop. |
| **Tap mode** | T: plays from 5 s before the selected word; each Space sets the current word's start to that moment, confirms it, and moves to the next word sung (any track). 1/2/3 play at 100/75/50% with pitch kept. After the last word the song plays 5 s more, then pauses. Esc ends. |
| **Anchor stretch** | Confirmed words are anchors. Unconfirmed words between two anchors are re-timed in proportion to fit between them; aligned words outside anchors stay put. |
| **Sung order** | All lyric lines across tracks, by start time: alignment, tapping and anchor stretch treat them as one sequence. |
| **Word timing** | Each word starts on its own time and ends with its line. Dragging a line's start or end edge carries its words along, each keeping its distance from that edge; the other edge stays. Dragging a word's right edge moves the line's end. |
| **Recent Projects** | The last 10 projects you opened or saved, listed on the New Project page. Click one to open it; Clear forgets the list (the projects stay). |
