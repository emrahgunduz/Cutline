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
| **Word** | One word inside a line, the lighter box. Orange when it isn't aligned yet. |
| **Snapping / snap guide** | Edges pulling toward nearby edges or the playhead, shown with a yellow line. Toggle with N; hold ⌘ to bypass. |
| **Project end** | Darker area after the last clip or audio. |

## Project concepts

| Term | What it is |
|---|---|
| **Project type** | Music video, Portrait social or Portrait ad. Each has its own size, length limit and codec. |
| **Transform** | A clip's scale and X/Y position. |
| **Filter** | A per-clip effect (Color, Fade) with an on/off switch. |
| **Lyric style** | The one font, size, color, position and drop shadow used for all lyrics. |
| **Proxy** | A smaller copy of a video used only for preview. Export always uses the original. |
| **Alignment** | Matching each lyric word to when it's sung in the song (coming in PR 2). |
| **Cinemascope / letterbox** | Animated black bars from 16:9 to 2.35:1 (coming in PR 3). |
| **Constant quality vs target bitrate** | The two export rate modes: fixed look with variable size, or fixed size with variable look. |
