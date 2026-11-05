import Foundation

/// A scene to place as a dummy: what the production document says about it.
struct PlacedScene: Equatable {
    var title: String
    var description: String
    var start: Double
    var end: Double
    var color: RGBA?
}

enum ControlToolError: LocalizedError, Equatable {
    case bad(String)
    var errorDescription: String? { if case .bad(let m) = self { return m } else { return nil } }
}

extension Project {
    static let dummiesTrackName = "Dummies"

    /// The track dummies go on when none is named: the one called "Dummies", else a new one on top.
    mutating func dummiesTrack() -> Int {
        if let i = videoTracks.firstIndex(where: { $0.name == Self.dummiesTrackName }) { return i }
        videoTracks.append(VideoTrack(name: Self.dummiesTrackName))
        return videoTracks.count - 1
    }

    /// Add a video track (tracks can be created this way, never deleted). `position`: "top"
    /// (default, drawn over the others), "bottom", or an index to go right above.
    mutating func createVideoTrack(name: String?, above index: Int?) -> Int {
        let track = VideoTrack(name: name.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : String($0.prefix(60)) })
        if let index, videoTracks.indices.contains(index) { videoTracks.insert(track, at: index + 1); return index + 1 }
        if index == -1 { videoTracks.insert(track, at: 0); return 0 }
        videoTracks.append(track)
        return videoTracks.count - 1
    }

    /// Remove the dummies on a track (only dummies: video and image clips stay), and the
    /// dummy cards nothing else uses. Returns how many clips were removed.
    @discardableResult
    mutating func clearDummies(onTrack t: Int) -> Int {
        guard videoTracks.indices.contains(t) else { return 0 }
        let removed = videoTracks[t].clips.filter { asset($0.assetID)?.isDummy == true }
        let ids = Set(removed.map(\.id))
        videoTracks[t].clips.removeAll { ids.contains($0.id) }
        let stillUsed = Set(videoTracks.flatMap(\.clips).map(\.assetID))
        let gone = Set(removed.map(\.assetID)).filter { !stillUsed.contains($0) }
        assets.removeAll { gone.contains($0.id) && $0.isDummy }
        return removed.count
    }

    /// The Dummies track's dummies (if there is such a track).
    @discardableResult
    mutating func clearDummiesTrack() -> Int {
        guard let t = videoTracks.firstIndex(where: { $0.name == Self.dummiesTrackName }) else { return 0 }
        return clearDummies(onTrack: t)
    }

    /// Create a dummy for each scene and place it on track `track` (nil = the Dummies track) at
    /// its time, on the frame grid. Song time is shifted by where the song starts on the
    /// timeline. With `replace`, the track's earlier dummies go first. A scene that would
    /// overlap anything left on the track (a video, an image, another dummy) or another scene
    /// stops the whole call: nothing is changed. Audio and lyrics are never touched.
    mutating func placeDummies(_ scenes: [PlacedScene], track: Int? = nil, songTime: Bool, replace: Bool,
                               defaults: DummyDefaults) throws -> [(asset: Asset, start: Double, end: Double)] {
        var next = self
        let t = track ?? next.dummiesTrack()
        guard next.videoTracks.indices.contains(t) else { throw ControlToolError.bad("no video track \(t)") }
        if replace { next.clearDummies(onTrack: t) }
        let offset = songTime ? (next.audio?.start ?? 0) : 0
        let eps = 1e-6
        var spans: [(Double, Double, String)] = next.videoTracks[t].clips.map { ($0.start, $0.end, next.asset($0.assetID)?.name ?? "a clip") }
        var placed: [(Asset, Double, Double)] = []
        for (i, s) in scenes.enumerated() {
            let start = next.quantize(max(0, s.start + offset)), end = max(start + next.frameDuration, next.quantize(s.end + offset))
            if let hit = spans.first(where: { $0.0 < end - eps && $0.1 > start + eps }) {
                throw ControlToolError.bad(String(format: "scene %d (%.2f–%.2f s) overlaps \"%@\" (%.2f–%.2f s) on that track; nothing was placed. Choose another track or create one.",
                                                  i + 1, start, end, hit.2, hit.0, hit.1))
            }
            let asset = next.addDummy(title: s.title, description: s.description, fontName: defaults.fontName,
                                      length: end - start, color: s.color ?? defaults.color)
            next.videoTracks[t].clips.append(Clip(assetID: asset.id, start: start, duration: end - start))
            spans.append((start, end, asset.name))
            placed.append((asset, start, end))
        }
        next.videoTracks[t].clips.sort { $0.start < $1.start }
        self = next
        return placed
    }

    /// A track by index (0 = bottom layer) or id.
    func videoTrackIndex(_ ref: JSONValue?) throws -> Int? {
        guard let ref, ref != .null else { return nil }
        if let n = ref.number {
            guard n == n.rounded(), videoTracks.indices.contains(Int(n)) else { throw ControlToolError.bad("no video track \(n); there are \(videoTracks.count) (0 = bottom)") }
            return Int(n)
        }
        if let s = ref.string {
            guard let i = videoTracks.firstIndex(where: { $0.id.uuidString.lowercased() == s.lowercased() }) else { throw ControlToolError.bad("no video track with id \(s)") }
            return i
        }
        throw ControlToolError.bad("track is an index (number) or an id (string)")
    }

    /// Every video track with what is on it, for list_video_tracks.
    var videoTrackListing: JSONValue {
        .array(videoTracks.enumerated().map { i, t in
            .object([
                "index": .number(Double(i)),
                "id": .string(t.id.uuidString.lowercased()),
                "name": .string(t.name ?? "Video \(i + 1)"),
                "hidden": .bool(t.isHidden),
                "items": .array(t.clips.sorted { $0.start < $1.start }.map { c in
                    let a = asset(c.assetID)
                    let kind = a?.isDummy == true ? "dummy" : (a?.kind == .image ? "image" : "video")
                    return .object(["id": .string(c.id.uuidString.lowercased()), "name": .string(a?.name ?? ""), "kind": .string(kind),
                                    "start": .number(c.start), "end": .number(c.end)])
                }),
            ])
        })
    }
}

/// The tools a connected client can call on its project.
enum ControlTools {
    static let all: [ControlToolInfo] = [
        ControlToolInfo(name: "project_info",
                        description: "The project's size, frame rate, length, where the song starts, and a summary of its video tracks.",
                        arguments: [:]),
        ControlToolInfo(name: "list_video_tracks",
                        description: "Every video track, bottom layer first (index 0 is drawn first; the highest index is on top), with its id, name, whether it's hidden, and what is on it: each item's id, name, kind (video, image or dummy), start and end in seconds (timeline time).",
                        arguments: [:]),
        ControlToolInfo(name: "create_video_track",
                        description: "Add an empty video track and return its index and id. Tracks can be created, never deleted.",
                        arguments: [
                            "name": "optional string shown in the track header",
                            "position": "\"top\" (default: drawn over everything), \"bottom\", or a track index or id to go right above",
                        ]),
        ControlToolInfo(name: "add_dummies",
                        description: "Create a dummy card for each scene and place it at the scene's start and end on a video track. Fails without changing anything if a scene would overlap anything else on that track (a video, an image or a dummy) or another scene. One undo step. Audio and lyrics are never changed.",
                        arguments: [
                            "scenes": "array of {title: string (empty = automatic name), description: string, start: seconds, end: seconds, color: optional \"#RRGGBB\"}",
                            "track": "optional index or id from list_video_tracks / create_video_track; default: the track named \"Dummies\" (made on top if missing)",
                            "time_base": "\"song\" (default: times are in the song; shifted by where the song starts on the timeline) or \"timeline\"",
                            "replace": "bool, default true: first remove the dummies already on that track (only dummies; videos and images stay)",
                        ]),
        ControlToolInfo(name: "remove_dummies",
                        description: "Remove the dummies on a video track (only dummies: videos and images stay) and the dummy cards nothing else uses. One undo step.",
                        arguments: ["track": "optional index or id; default: the track named \"Dummies\""]),
    ]

    static let maxScenes = 1000

    static func hexColor(_ s: String) -> RGBA? {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return RGBA(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255, a: 1)
    }

    /// Read and check add_dummies' scenes.
    static func scenes(_ args: JSONValue?) throws -> [PlacedScene] {
        guard let list = args?["scenes"]?.array else { throw ControlToolError.bad("add_dummies needs \"scenes\": an array") }
        guard !list.isEmpty else { throw ControlToolError.bad("\"scenes\" is empty") }
        guard list.count <= maxScenes else { throw ControlToolError.bad("at most \(maxScenes) scenes at a time") }
        return try list.enumerated().map { i, v in
            guard let start = v["start"]?.number, let end = v["end"]?.number else { throw ControlToolError.bad("scene \(i + 1): needs numeric start and end (seconds)") }
            guard start >= 0, end > start, end - start <= 3600 else { throw ControlToolError.bad("scene \(i + 1): start must be ≥ 0 and end after start (at most an hour long)") }
            var color: RGBA?
            if let c = v["color"]?.string { guard let rgba = hexColor(c) else { throw ControlToolError.bad("scene \(i + 1): color must be #RRGGBB") }; color = rgba }
            return PlacedScene(title: String((v["title"]?.string ?? "").prefix(200)), description: String((v["description"]?.string ?? "").prefix(4000)),
                               start: start, end: end, color: color)
        }
    }

    static func summary(_ id: String, _ doc: ProjectDocument) -> ControlProjectSummary {
        let p = doc.editor.project
        return ControlProjectSummary(id: id, name: doc.displayName, path: doc.fileURL?.path, type: p.type.rawValue,
                                     width: p.canvas.width, height: p.canvas.height, fps: p.fps, duration: p.duration,
                                     songStart: p.audio?.start, songLength: p.audio?.duration)
    }

    /// Run a tool on the project.
    @MainActor
    static func call(_ tool: String, args: JSONValue?, on editor: EditorModel, client: String) throws -> JSONValue {
        switch tool {
        case "project_info":
            let p = editor.project
            let dummies = p.videoTracks.first { $0.name == Project.dummiesTrackName }?.clips.compactMap { c -> JSONValue? in
                guard let a = p.asset(c.assetID), let card = a.dummy else { return nil }
                return .object(["title": .string(card.title), "description": .string(card.sceneDescription),
                                "start": .number(c.start), "end": .number(c.end)])
            } ?? []
            return .object([
                "width": .number(Double(p.canvas.width)), "height": .number(Double(p.canvas.height)), "fps": .number(p.fps),
                "duration": .number(p.duration), "song_start": p.audio.map { .number($0.start) } ?? .null,
                "song_length": p.audio.map { .number($0.duration) } ?? .null,
                "video_tracks": .array(p.videoTracks.enumerated().map { i, t in .object(["index": .number(Double(i)), "name": .string(t.name ?? "Video \(i + 1)"), "items": .number(Double(t.clips.count))]) }),
                "dummies_track": .array(dummies),
            ])
        case "list_video_tracks":
            return .object(["tracks": editor.project.videoTrackListing, "note": .string("index 0 is the bottom layer; the highest index is drawn on top")])
        case "create_video_track":
            var above: Int?
            if let pos = args?["position"] {
                if pos.string == "top" { above = nil }
                else if pos.string == "bottom" { above = -1 }
                else { above = try editor.project.videoTrackIndex(pos) }
            }
            var index = 0
            editor.edit("New Video Track (\(client))") { p in index = p.createVideoTrack(name: args?["name"]?.string, above: above) }
            let t = editor.project.videoTracks[index]
            return .object(["index": .number(Double(index)), "id": .string(t.id.uuidString.lowercased()), "name": .string(t.name ?? "Video \(index + 1)")])
        case "add_dummies":
            let scenes = try scenes(args)
            for (i, a) in scenes.enumerated() {
                if let b = scenes.dropFirst(i + 1).first(where: { $0.start < a.end && $0.end > a.start }) {
                    throw ControlToolError.bad("scenes \"\(a.title)\" and \"\(b.title)\" overlap; nothing was placed")
                }
            }
            let base = args?["time_base"]?.string ?? "song"
            guard base == "song" || base == "timeline" else { throw ControlToolError.bad("time_base is \"song\" or \"timeline\"") }
            let replace = args?["replace"]?.bool ?? true
            let track = try editor.project.videoTrackIndex(args?["track"])
            let defaults = editor.project.dummyDefaults ?? DummyDefaults()
            var trial = editor.project
            _ = try trial.placeDummies(scenes, track: track, songTime: base == "song", replace: replace, defaults: defaults)   // checks first
            var placed: [(asset: Asset, start: Double, end: Double)] = []
            editor.edit("Place Dummies (\(client))") { p in
                placed = (try? p.placeDummies(scenes, track: track, songTime: base == "song", replace: replace, defaults: defaults)) ?? []
            }
            for a in placed { Task { await editor.thumbnails.ensureThumbnail(for: a.asset) } }
            let t = track ?? editor.project.videoTracks.firstIndex { $0.name == Project.dummiesTrackName } ?? 0
            return .object(["placed": .array(placed.map { .object(["title": .string($0.asset.name), "start": .number($0.start), "end": .number($0.end)]) }),
                            "track": .object(["index": .number(Double(t)), "id": .string(editor.project.videoTracks[t].id.uuidString.lowercased()),
                                              "name": .string(editor.project.videoTracks[t].name ?? "Video \(t + 1)")])])
        case "remove_dummies":
            let track = try editor.project.videoTrackIndex(args?["track"])
            var removed = 0
            editor.edit("Remove Dummies (\(client))") { p in removed = track.map { p.clearDummies(onTrack: $0) } ?? p.clearDummiesTrack() }
            return .object(["removed": .number(Double(removed))])
        default:
            throw ControlToolError.bad("unknown tool \"\(tool)\"; ask for tools first")
        }
    }
}
