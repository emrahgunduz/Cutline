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

    /// The track dummies are placed on: the one named "Dummies", else a new one on top.
    mutating func dummiesTrack() -> Int {
        if let i = videoTracks.firstIndex(where: { $0.name == Self.dummiesTrackName }) { return i }
        videoTracks.append(VideoTrack(name: Self.dummiesTrackName))
        return videoTracks.count - 1
    }

    /// Remove what is on the Dummies track, and the dummies it used that nothing else uses.
    /// Returns how many clips were removed.
    @discardableResult
    mutating func clearDummiesTrack() -> Int {
        guard let t = videoTracks.firstIndex(where: { $0.name == Self.dummiesTrackName }) else { return 0 }
        let removed = videoTracks[t].clips
        videoTracks[t].clips = []
        let stillUsed = Set(videoTracks.flatMap(\.clips).map(\.assetID))
        let gone = Set(removed.map(\.assetID)).filter { !stillUsed.contains($0) }
        assets.removeAll { gone.contains($0.id) && $0.isDummy }
        return removed.count
    }

    /// Create a dummy for each scene and place it on the Dummies track at its time (on the frame
    /// grid). Song time is shifted by where the song starts on the timeline. Audio and lyrics
    /// are not touched. Returns the placed clips' (asset, start, end) in scene order.
    mutating func placeDummies(_ scenes: [PlacedScene], songTime: Bool, replace: Bool, defaults: DummyDefaults) -> [(asset: Asset, start: Double, end: Double)] {
        if replace { clearDummiesTrack() }
        let t = dummiesTrack()
        let offset = songTime ? (audio?.start ?? 0) : 0
        var out: [(Asset, Double, Double)] = []
        for s in scenes {
            let start = quantize(max(0, s.start + offset)), end = max(start + frameDuration, quantize(s.end + offset))
            let asset = addDummy(title: s.title, description: s.description, fontName: defaults.fontName,
                                 length: end - start, color: s.color ?? defaults.color)
            var clip = Clip(assetID: asset.id, start: start, duration: end - start)
            clip.transform.scale = 1
            videoTracks[t].clips.append(clip)
            out.append((asset, start, end))
        }
        videoTracks[t].clips.sort { $0.start < $1.start }
        return out
    }
}

/// The tools a connected client can call on its project.
enum ControlTools {
    static let all: [ControlToolInfo] = [
        ControlToolInfo(name: "project_info",
                        description: "The project's size, frame rate, length, where the song starts, its video tracks, and the dummies already on the Dummies track.",
                        arguments: [:]),
        ControlToolInfo(name: "add_dummies",
                        description: "Create a dummy card for each scene and place it on the Dummies video track (made on top if missing) at the scene's start and end. One undo step. Audio and lyrics are never changed.",
                        arguments: [
                            "scenes": "array of {title: string (empty = automatic name), description: string, start: seconds, end: seconds, color: optional \"#RRGGBB\"}",
                            "time_base": "\"song\" (default: times are in the song; shifted by where the song starts on the timeline) or \"timeline\"",
                            "replace": "bool, default true: first remove the dummies already on the Dummies track",
                        ]),
        ControlToolInfo(name: "remove_dummies",
                        description: "Remove everything on the Dummies track, and the dummy cards only it used. One undo step.",
                        arguments: [:]),
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
                "video_tracks": .array(p.videoTracks.enumerated().map { i, t in .object(["name": .string(t.name ?? "Video \(i + 1)"), "clips": .number(Double(t.clips.count))]) }),
                "dummies": .array(dummies),
            ])
        case "add_dummies":
            let scenes = try scenes(args)
            let base = args?["time_base"]?.string ?? "song"
            guard base == "song" || base == "timeline" else { throw ControlToolError.bad("time_base is \"song\" or \"timeline\"") }
            let replace = args?["replace"]?.bool ?? true
            let defaults = editor.project.dummyDefaults ?? DummyDefaults()
            var placed: [(asset: Asset, start: Double, end: Double)] = []
            editor.edit("Place Dummies (\(client))") { p in placed = p.placeDummies(scenes, songTime: base == "song", replace: replace, defaults: defaults) }
            for a in placed { Task { await editor.thumbnails.ensureThumbnail(for: a.asset) } }
            return .object(["placed": .array(placed.map { .object(["title": .string($0.asset.name), "start": .number($0.start), "end": .number($0.end)]) }),
                            "track": .string(Project.dummiesTrackName)])
        case "remove_dummies":
            var removed = 0
            editor.edit("Remove Dummies (\(client))") { p in removed = p.clearDummiesTrack() }
            return .object(["removed": .number(Double(removed))])
        default:
            throw ControlToolError.bad("unknown tool \"\(tool)\"; ask for tools first")
        }
    }
}
