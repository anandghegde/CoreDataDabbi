import AppKit

/// The menu bar, in code: the app has no nib (PRD §8.2).
///
/// Items target the responder chain. What a project window can do is validated by `ProjectWindowController`,
/// the document actions by `NSDocument`, and the rest by AppKit.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu(title: "Main Menu")
        for menu in [application(), file(), edit(), view(), data(), go(), window(), help()] {
            let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        return main
    }

    // MARK: Menus

    private static func application() -> NSMenu {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "CoreDataDabbi"
        let menu = NSMenu(title: name)
        menu.addItem(
            item(String(localized: "About \(name)"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())
        let services = NSMenuItem(title: String(localized: "Services"), action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: services.title)
        NSApp.servicesMenu = services.submenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Hide \(name)"), #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(
            item(
                String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h",
                [.command, .option]))
        menu.addItem(item(String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Quit \(name)"), #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func file() -> NSMenu {
        let menu = NSMenu(title: String(localized: "File"))
        menu.addItem(
            item(
                String(localized: "Browse Simulators…"), #selector(DocumentController.browseSimulators(_:)), "n",
                [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Open…"), #selector(NSDocumentController.openDocument(_:)), "o"))
        menu.addItem(
            item(
                String(localized: "Open Database…"), #selector(DocumentController.openDatabase(_:)), "o",
                [.command, .shift]))

        // AppKit fills the menu that holds this item with the recent documents.
        let recents = NSMenuItem(title: String(localized: "Open Recent"), action: nil, keyEquivalent: "")
        recents.submenu = NSMenu(title: recents.title)
        recents.submenu?.addItem(
            item(String(localized: "Clear Menu"), #selector(NSDocumentController.clearRecentDocuments(_:))))
        menu.addItem(recents)

        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Close"), #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item(String(localized: "Save…"), #selector(NSDocument.save(_:)), "s"))
        menu.addItem(
            item(String(localized: "Duplicate"), #selector(NSDocument.duplicate(_:)), "s", [.command, .shift]))
        menu.addItem(item(String(localized: "Rename…"), #selector(NSDocument.rename(_:))))
        menu.addItem(item(String(localized: "Move To…"), #selector(NSDocument.move(_:))))
        menu.addItem(item(String(localized: "Revert To Saved"), #selector(NSDocument.revertToSaved(_:))))
        menu.addItem(.separator())
        menu.addItem(
            item(
                String(localized: "Reload Store"), #selector(ProjectWindowController.reloadStore(_:)), "r",
                [.command, .shift]))
        menu.addItem(
            item(String(localized: "Show Store in Finder"), #selector(ProjectWindowController.revealStore(_:))))
        return menu
    }

    private static func edit() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Edit"))
        menu.addItem(item(String(localized: "Undo"), Selector(("undo:")), "z"))
        menu.addItem(item(String(localized: "Redo"), Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Cut"), #selector(NSText.cut(_:)), "x"))
        menu.addItem(item(String(localized: "Copy"), #selector(NSText.copy(_:)), "c"))
        menu.addItem(item(String(localized: "Paste"), #selector(NSText.paste(_:)), "v"))
        menu.addItem(item(String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a"))
        return menu
    }

    private static func view() -> NSMenu {
        let menu = NSMenu(title: String(localized: "View"))
        menu.addItem(
            item(
                String(localized: "Show Sidebar"), #selector(NSSplitViewController.toggleSidebar(_:)), "s",
                [.command, .control]))
        menu.addItem(
            item(
                String(localized: "Show Bottom Panel"), #selector(ProjectWindowController.toggleBottomPanel(_:)), "y",
                [.command, .shift]))
        menu.addItem(
            item(
                String(localized: "Show Inspector"), #selector(NSSplitViewController.toggleInspector(_:)), "0",
                [.command, .option]))
        menu.addItem(.separator())

        // The predicate bar, where the rows on screen are narrowed down (§7.1). ⌥⌘F puts the keyboard in it
        // from wherever the window is; ⌘F in the quick filter at its end, which is Find for a table (PRD-6).
        menu.addItem(
            item(String(localized: "Search Rows"), #selector(ProjectWindowController.focusQuickFilter(_:)), "f"))
        menu.addItem(
            item(
                String(localized: "Filter Rows"), #selector(ProjectWindowController.focusFilter(_:)), "f",
                [.command, .option]))
        menu.addItem(
            item(
                String(localized: "Show Predicate Builder"),
                #selector(ProjectWindowController.togglePredicateBuilder(_:)), "b", [.command, .option]))
        // A predicate worth keeping is kept in the project, and listed in the sidebar (PRD-3).
        menu.addItem(
            item(
                String(localized: "New Predicate"), #selector(ProjectWindowController.newPredicate(_:)), "n",
                [.command, .option]))
        menu.addItem(
            item(
                String(localized: "Save Predicate"), #selector(ProjectWindowController.savePredicate(_:)), "s",
                [.command, .option]))
        menu.addItem(.separator())

        // Somewhere to send the keyboard, for people who do not use a pointer and for panes that are shut
        // (§8.4). ⌃⌘1…5 read left to right, as the window does.
        let focus = NSMenuItem(title: String(localized: "Focus"), action: nil, keyEquivalent: "")
        focus.submenu = NSMenu(title: focus.title)
        for (index, pane) in Pane.focusable.enumerated() {
            let entry = item(
                Pane.name(of: pane), #selector(ProjectWindowController.focusPane(_:)), "\(index + 1)",
                [.command, .control])
            entry.representedObject = pane
            focus.submenu?.addItem(entry)
        }
        menu.addItem(focus)

        menu.addItem(.separator())
        menu.addItem(
            item(
                String(localized: "Show Toolbar"), #selector(NSWindow.toggleToolbarShown(_:)), "t",
                [.command, .option]))
        menu.addItem(
            item(String(localized: "Customize Toolbar…"), #selector(NSWindow.runToolbarCustomizationPalette(_:))))
        menu.addItem(.separator())
        menu.addItem(
            item(
                String(localized: "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f",
                [.command, .control]))
        return menu
    }

    /// What the store is doing while the window is open (TRK-1, TRK-9).
    private static func data() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Data"))
        // Play and Stop as one item whose title says which it is. Shift-Command-R is Reload Store, so tracking
        // takes the plain one.
        menu.addItem(
            item(String(localized: "Track Changes"), #selector(ProjectWindowController.toggleTracking(_:)), "r"))
        menu.addItem(
            item(
                String(localized: "Pause Tracking"), #selector(ProjectWindowController.pauseTracking(_:)), "r",
                [.command, .option]))
        menu.addItem(
            item(
                String(localized: "Clear Log"), #selector(ProjectWindowController.clearTracking(_:)), "k",
                [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Show Rows"), #selector(ProjectWindowController.showRows(_:))))
        return menu
    }

    private static func go() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Go"))
        menu.addItem(item(String(localized: "Back"), #selector(ProjectWindowController.goBack(_:)), "["))
        menu.addItem(item(String(localized: "Forward"), #selector(ProjectWindowController.goForward(_:)), "]"))
        menu.addItem(.separator())
        // The keyboard's way to follow a relationship, which until now took a double-click (REL-3).
        menu.addItem(
            item(
                String(localized: "Reveal in Entity"), #selector(ProjectWindowController.revealInEntity(_:)), "r",
                [.command, .control]))
        return menu
    }

    private static func window() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Window"))
        menu.addItem(
            item(
                String(localized: "Welcome to CoreDataDabbi"),
                #selector(DocumentController.showWelcomeWindow(_:)), "0", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item(String(localized: "Zoom"), #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))))
        // AppKit adds the tab items and the list of windows.
        NSApp.windowsMenu = menu
        return menu
    }

    private static func help() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Help"))
        NSApp.helpMenu = menu
        return menu
    }

    // MARK: Items

    private static func item(
        _ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
