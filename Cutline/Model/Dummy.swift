import Foundation

/// A placeholder card: a colored frame with a title and its length, standing in for a shot
/// that doesn't exist yet. It is an image asset Cutline draws itself (no file on disk), at the
/// project's size, and its clips default to its length.
struct DummyCard: Codable, Equatable, Hashable {
    var title: String
    /// What the scene is (several lines allowed); empty = none.
    var sceneDescription: String = ""
    /// Font family name ("Helvetica Neue").
    var fontName: String
    /// Seconds; also the length of the clip when the dummy is dropped on the timeline.
    var length: Double
    var color: RGBA

    enum CodingKeys: String, CodingKey { case title, sceneDescription = "description", fontName, length, color }

    init(title: String, sceneDescription: String = "", fontName: String, length: Double, color: RGBA) {
        self.title = title; self.sceneDescription = sceneDescription; self.fontName = fontName; self.length = length; self.color = color
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        sceneDescription = try c.decodeIfPresent(String.self, forKey: .sceneDescription) ?? ""
        fontName = try c.decode(String.self, forKey: .fontName)
        length = try c.decode(Double.self, forKey: .length)
        color = try c.decode(RGBA.self, forKey: .color)
    }

    /// The second line on the card: "12 seconds", "1.5 seconds".
    var lengthText: String {
        let s = length.rounded() == length ? String(Int(length)) : String(format: "%.1f", length)
        return s + (length == 1 ? " second" : " seconds")
    }
}

/// The New Dummy sheet's last choices, remembered per project.
struct DummyDefaults: Codable, Equatable {
    var fontName: String = DummyDefaults.defaultFont
    /// Empty = automatic names (Dummy 0001, Dummy 0002 ...).
    var title: String = ""
    var length: Double = 5
    var color = RGBA(r: 0.20, g: 0.24, b: 0.32, a: 1)

    static let defaultFont = "Helvetica Neue"
}

extension RGBA: Hashable {
    func hash(into h: inout Hasher) { h.combine(r); h.combine(g); h.combine(b); h.combine(a) }
}

extension Project {
    static let dummyPrefix = "Dummy "

    /// The automatic name for the next dummy: one more than the highest "Dummy NNNN" dummy in
    /// the project, starting at 0001 (dummies you named yourself don't count).
    var nextDummyName: String {
        let used = assets.filter(\.isDummy).compactMap { a -> Int? in
            guard a.name.hasPrefix(Self.dummyPrefix) else { return nil }
            return Int(a.name.dropFirst(Self.dummyPrefix.count))
        }
        return Self.dummyPrefix + String(format: "%04d", (used.max() ?? 0) + 1)
    }

    /// Add a dummy to the assets (not the timeline). An empty title takes the automatic name.
    @discardableResult
    mutating func addDummy(title: String, description: String = "", fontName: String, length: Double, color: RGBA) -> Asset {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? nextDummyName : trimmed
        let card = DummyCard(title: name, sceneDescription: description.trimmingCharacters(in: .whitespacesAndNewlines),
                             fontName: fontName, length: max(frameDuration, length), color: color)
        var asset = Asset(kind: .image, name: name, path: "", pixelSize: canvas, duration: card.length)
        asset.dummy = card
        assets.append(asset)
        return asset
    }
}

extension EditorModel {
    /// Create the dummy (one undo step), remember the choices, and select it in the assets.
    @MainActor
    @discardableResult
    func createDummy(_ d: DummyDefaults, description: String = "") -> Asset? {
        rememberDummyDefaults(d)
        var made: Asset?
        edit("New Dummy") { p in made = p.addDummy(title: d.title, description: description, fontName: d.fontName, length: d.length, color: d.color) }
        guard let asset = made else { return nil }
        selectedAssets = [asset.id]
        Task { await thumbnails.ensureThumbnail(for: asset) }
        return asset
    }
}
