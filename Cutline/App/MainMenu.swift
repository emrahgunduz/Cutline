import AppKit

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Cutline", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Cutline", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Cutline", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Project…", action: #selector(NSDocumentController.newDocument(_:)), keyEquivalent: "n")
        file.addItem(withTitle: "Open…", action: #selector(NSDocumentController.openDocument(_:)), keyEquivalent: "o")
        file.addItem(.separator())
        file.addItem(withTitle: "Import Media…", action: #selector(MainWindowController.importMedia(_:)), keyEquivalent: "i")
        file.addItem(withTitle: "Export…", action: #selector(MainWindowController.showExport(_:)), keyEquivalent: "e")
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        file.addItem(withTitle: "Save", action: #selector(NSDocument.save(_:)), keyEquivalent: "s")
        let saveAs = file.addItem(withTitle: "Save As…", action: #selector(NSDocument.saveAs(_:)), keyEquivalent: "s")
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        fileItem.submenu = file
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let lyricsItem = NSMenuItem()
        let lyrics = NSMenu(title: "Lyrics")
        let align = lyrics.addItem(withTitle: "Align Words to Song", action: #selector(MainWindowController.alignLyrics(_:)), keyEquivalent: "l")
        align.keyEquivalentModifierMask = [.command, .option]
        lyrics.addItem(withTitle: "Analyze Song Again", action: #selector(MainWindowController.analyzeSongAgain(_:)), keyEquivalent: "")
        lyrics.addItem(.separator())
        // Plain-key shortcuts (N, Return, T) are handled by the window, so they show in the titles.
        lyrics.addItem(withTitle: "Next Unsure Word  (N)", action: #selector(MainWindowController.nextUnsureWord(_:)), keyEquivalent: "")
        lyrics.addItem(withTitle: "Previous Unsure Word  (⇧N)", action: #selector(MainWindowController.previousUnsureWord(_:)), keyEquivalent: "")
        lyrics.addItem(withTitle: "Confirm Word  (Return)", action: #selector(MainWindowController.confirmWord(_:)), keyEquivalent: "")
        lyrics.addItem(withTitle: "Stop Looping  (Esc)", action: #selector(MainWindowController.stopLooping(_:)), keyEquivalent: "")
        lyrics.addItem(.separator())
        lyrics.addItem(withTitle: "Tap Mode  (T)", action: #selector(MainWindowController.toggleTapMode(_:)), keyEquivalent: "")
        lyrics.addItem(withTitle: "Tap  (Space in tap mode)", action: #selector(MainWindowController.tapWord(_:)), keyEquivalent: "")
        let speed = NSMenuItem(title: "Tap Speed", action: nil, keyEquivalent: "")
        let speeds = NSMenu(title: "Tap Speed")
        for (i, r) in EditorModel.tapRates.enumerated() {
            let item = speeds.addItem(withTitle: "\(Int(r * 100))%  (\(i + 1))", action: #selector(MainWindowController.setTapSpeed(_:)), keyEquivalent: "")
            item.tag = i
        }
        speed.submenu = speeds
        lyrics.addItem(speed)
        lyricsItem.submenu = lyrics
        main.addItem(lyricsItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window
        return main
    }
}
