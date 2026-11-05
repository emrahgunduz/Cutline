import AppKit
import NaturalLanguage

/// The language Whisper uses to double-check aligned words. A project either names one
/// (`Project.lyricsLanguage`) or detects it from the lyric text.
enum LyricsLanguage {
    /// Every language the bundled Whisper model knows (its own codes).
    static let codes = ["af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo", "br", "bs", "ca", "cs", "cy", "da", "de",
                        "el", "en", "es", "et", "eu", "fa", "fi", "fo", "fr", "gl", "gu", "ha", "haw", "he", "hi", "hr", "ht",
                        "hu", "hy", "id", "is", "it", "ja", "jw", "ka", "kk", "km", "kn", "ko", "la", "lb", "ln", "lo", "lt",
                        "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt", "my", "ne", "nl", "nn", "no", "oc", "pa", "pl",
                        "ps", "pt", "ro", "ru", "sa", "sd", "si", "sk", "sl", "sn", "so", "sq", "sr", "su", "sv", "sw", "ta",
                        "te", "tg", "th", "tk", "tl", "tr", "tt", "uk", "ur", "uz", "vi", "yi", "yo", "zh", "yue"]

    /// Display name in the user's language ("jw" is Whisper's code for Javanese, ISO "jv").
    static func name(_ code: String) -> String {
        let iso = code == "jw" ? "jv" : code
        return Locale.current.localizedString(forLanguageCode: iso)?.localizedCapitalized ?? code
    }

    /// All languages, sorted by their display name.
    static var sorted: [(code: String, name: String)] {
        codes.map { ($0, name($0)) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The language the lyrics are written in, as a Whisper code (nil when unsure, which
    /// lets Whisper detect it from the audio).
    static func detect(_ words: [String]) -> String? {
        let text = words.joined(separator: " ")
        guard !text.isEmpty else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        // Turkish letters are a strong hint that short lyric samples can miss.
        if text.contains(where: Set("çğıöşüÇĞİÖŞÜ").contains),
           (recognizer.languageHypotheses(withMaximum: 3)[.turkish] ?? 0) > 0.05 || recognizer.dominantLanguage == nil {
            return "tr"
        }
        guard let lang = recognizer.dominantLanguage,
              (recognizer.languageHypotheses(withMaximum: 1)[lang] ?? 0) >= 0.5 else { return nil }
        var code = String(lang.rawValue.prefix { $0 != "-" })
        if code == "nb" { code = "no" }
        if code == "jv" { code = "jw" }
        return codes.contains(code) ? code : nil
    }

    /// The language to send for `project`: its chosen one, or the one its lyrics are in.
    static func resolved(for project: Project) -> String? {
        project.lyricsLanguage ?? detect(project.lyricTracks.flatMap(\.lines).flatMap(\.words).map(\.text))
    }

    /// A menu of "Detect from Lyrics" plus every language, the current choice checked.
    /// `choose` receives nil for detection or a language code.
    static func menu(selected: String?, title: String = "Lyrics Language", choose: @escaping (String?) -> Void) -> NSMenu {
        let menu = NSMenu(title: title)
        func add(_ label: String, _ code: String?) {
            let handler = MenuHandler { choose(code) }
            let item = NSMenuItem(title: label, action: #selector(MenuHandler.run), keyEquivalent: "")
            item.target = handler
            item.representedObject = handler
            item.state = code == selected ? .on : .off
            menu.addItem(item)
        }
        add("Detect from Lyrics", nil)
        menu.addItem(.separator())
        for l in sorted { add(l.name, l.code) }
        return menu
    }
}

/// Runs a closure from a menu item (kept alive by the item's representedObject).
final class MenuHandler: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func run() { action() }
}
