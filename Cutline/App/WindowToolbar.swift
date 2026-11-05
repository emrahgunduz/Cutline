import AppKit
import Combine

/// The main window's toolbar: import, undo/redo, edit actions, project format, export.
final class WindowToolbar: NSObject, NSToolbarDelegate, NSToolbarItemValidation {
    private weak var editor: EditorModel?
    private weak var windowController: MainWindowController?
    private let infoField = NSTextField(labelWithString: "")
    private var cancellables: Set<AnyCancellable> = []

    private enum ID {
        static let importMedia = NSToolbarItem.Identifier("import")
        static let undo = NSToolbarItem.Identifier("undo")
        static let redo = NSToolbarItem.Identifier("redo")
        static let split = NSToolbarItem.Identifier("split")
        static let delete = NSToolbarItem.Identifier("delete")
        static let addVideo = NSToolbarItem.Identifier("addVideo")
        static let addLyrics = NSToolbarItem.Identifier("addLyrics")
        static let info = NSToolbarItem.Identifier("info")
        static let export = NSToolbarItem.Identifier("export")
        static let clearCache = NSToolbarItem.Identifier("clearCache")
        static let resetCaches = NSToolbarItem.Identifier("resetCaches")
    }

    init(editor: EditorModel, windowController: MainWindowController) {
        self.editor = editor
        self.windowController = windowController
        super.init()
        infoField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        infoField.textColor = .secondaryLabelColor
        editor.$revision.receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshInfo() }.store(in: &cancellables)
        editor.$segmentFiles.receive(on: RunLoop.main).sink { [weak self] _ in self?.refreshCacheSize() }.store(in: &cancellables)
    }

    func install(on window: NSWindow) {
        // A new identifier so the saved layout from before the cache buttons doesn't hide them.
        let toolbar = NSToolbar(identifier: "CutlineMain2")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        self.toolbar = toolbar
        refreshInfo()
    }

    private func refreshInfo() {
        guard let p = editor?.project else { return }
        let limit = Presets.preset(for: p.type).maxDuration.map { " · max \(Timecode.string($0, fps: p.fps).dropLast(3))" } ?? ""
        infoField.stringValue = "\(p.type.title) · \(p.canvas.width)×\(p.canvas.height) · \(Int(p.fps.rounded())) fps\(limit)"
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ID.importMedia, .space, ID.undo, ID.redo, .space, ID.split, ID.delete, ID.addVideo, ID.addLyrics,
         .flexibleSpace, ID.info, .flexibleSpace, ID.clearCache, ID.resetCaches, ID.export]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space, .flexibleSpace]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func item(_ label: String, _ symbol: String, _ tip: String, _ action: Selector) -> NSToolbarItem {
            let i = NSToolbarItem(itemIdentifier: id)
            i.label = label
            i.paletteLabel = label
            i.toolTip = tip
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            i.target = self
            i.action = action
            i.isBordered = true
            return i
        }
        switch id {
        case ID.importMedia: return item("Import", "square.and.arrow.down", "Import media (⌘I)", #selector(importMedia))
        case ID.undo: return item("Undo", "arrow.uturn.backward", "Undo (⌘Z)", #selector(undo))
        case ID.redo: return item("Redo", "arrow.uturn.forward", "Redo (⇧⌘Z)", #selector(redo))
        case ID.split: return item("Split", "scissors", "Cut at playhead (C)", #selector(split))
        case ID.delete: return item("Delete", "trash", "Delete selection (⌫)", #selector(delete))
        case ID.addVideo: return item("Video Track", "rectangle.stack.badge.plus", "Add a video track", #selector(addVideo))
        case ID.addLyrics: return item("Lyrics Track", "text.badge.plus", "Add a lyrics track", #selector(addLyrics))
        case ID.export: return item("Export", "square.and.arrow.up", "Export the video (⌘E)", #selector(export))
        case ID.clearCache:
            let i = item("Clear Cache", "externaldrive.badge.xmark", "Empty the render cache (preview frames and export segments). Proxies, thumbnails, waveforms and analysis are kept.", #selector(clearCache))
            let bytes = editor?.renderCacheBytes ?? 0
            if bytes > 0 { i.label = "Clear Cache (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))" }
            return i
        case ID.resetCaches:
            return item("Reset Caches", "arrow.triangle.2.circlepath", "Rebuild thumbnails, waveforms, music analysis or proxies…", #selector(resetCaches))
        case ID.info:
            let i = NSToolbarItem(itemIdentifier: id)
            i.label = "Project"
            i.paletteLabel = "Project format"
            i.view = infoField
            return i
        default: return nil
        }
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        guard let editor else { return false }
        switch item.itemIdentifier {
        case ID.undo: return editor.undoManager?.canUndo ?? false
        case ID.redo: return editor.undoManager?.canRedo ?? false
        case ID.delete: return editor.selection != .none
        case ID.split: return !editor.project.videoTracks.flatMap(\.clips).isEmpty
        case ID.export: return editor.project.duration > 0
        case ID.resetCaches: return editor.mediaResetMessage == nil
        default: return true
        }
    }

    @objc private func importMedia() { windowController?.importMedia(nil) }
    @objc private func undo() { editor?.undoManager?.undo() }
    @objc private func redo() { editor?.undoManager?.redo() }
    @objc private func split() { editor?.splitAtPlayhead() }
    @objc private func delete() { editor?.deleteSelection() }
    @objc private func addVideo() { editor?.edit("Add Video Track") { $0.addVideoTrack() } }
    @objc private func addLyrics() { editor?.edit("Add Lyrics Track") { $0.addLyricTrack() } }
    @objc private func export() { windowController?.showExport(nil) }
    @objc private func clearCache() { windowController?.clearRenderCache(nil) }
    @objc private func resetCaches() { windowController?.resetMediaCaches(nil) }

    private weak var toolbar: NSToolbar?

    /// The Clear Cache label shows how much the render cache holds. Looked up in the toolbar's
    /// live items: AppKit may build more than one item per identifier (overflow, customizing).
    func refreshCacheSize() {
        guard let editor, let toolbar else { return }
        let bytes = editor.renderCacheBytes
        let label = bytes > 0 ? "Clear Cache (\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)))" : "Clear Cache"
        for item in toolbar.items where item.itemIdentifier == ID.clearCache { item.label = label }
    }
}
