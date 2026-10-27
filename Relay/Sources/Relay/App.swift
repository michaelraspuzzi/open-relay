import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Transparent window with a hidden titlebar: Relay draws its own top bar, traffic lights and rounded glass edge,
/// while macOS still handles moving, resizing and tiling (drag to a screen edge for half screen).
final class RelayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: RelayWindow!
    private var model: RelayModel!
    private var monitors: [Any] = []
    private var appearanceObserver: NSKeyValueObservation?
    private var remote: RemoteServer!
    private var pairWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Watchdog.start()
        model = RelayModel()
        model.onDismiss = { [weak self] in self?.hide() }
        model.onMinimize = { [weak self] in self?.window.miniaturize(nil) }
        if Snapshot.runIfRequested(model: model) { exit(0) }
        Task { if await DrawingTest.runIfRequested() { exit(0) } }
        // macOS 26's "Default" icon style always shows the light icon, so swap it by hand while running
        // (the RelayDock plugin does the same while Relay is closed).
        NSApp.applicationIconImage = Assets.appIcon
        appearanceObserver = NSApp.observe(\.effectiveAppearance) { _, _ in
            Task { @MainActor in NSApp.applicationIconImage = Assets.appIcon }
        }
        buildMenu()

        let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        window = RelayWindow(contentRect: frame, styleMask: [.titled, .resizable, .fullSizeContentView, .miniaturizable], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { window.standardWindowButton(button)?.isHidden = true }
        window.minSize = NSSize(width: 560, height: 520)
        window.collectionBehavior = [.fullScreenAuxiliary, .managed]
        let host = NSHostingView(rootView: RootView(model: model))
        // The hidden titlebar would otherwise inset the content, leaving a see-through strip above Relay's own top bar.
        host.safeAreaRegions = []
        window.contentView = host
        // First launch fills the screen (a titled window's contentRect would grow by the titlebar);
        // after that it remembers where you put it and how wide.
        window.setFrame(frame, display: false)
        // Test hook: RELAY_SCREEN=<index> fills that display instead (and leaves the saved frame alone).
        if let index = ProcessInfo.processInfo.environment["RELAY_SCREEN"].flatMap(Int.init), NSScreen.screens.indices.contains(index) {
            window.setFrame(NSScreen.screens[index].visibleFrame, display: false)
        } else {
            window.setFrameAutosaveName("RelayMain")
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        // Test hook: float above other apps so an automated screenshot sees Relay.
        if ProcessInfo.processInfo.environment["RELAY_FLOAT"] != nil { window.level = .floating }

        installKeyboard()
        // Test hook: RELAY_AUTOSEND types this into the composer and presses Return a few seconds after launch.
        if let text = ProcessInfo.processInfo.environment["RELAY_AUTOSEND"] {
            Task { @MainActor [model] in
                try? await Task.sleep(for: .seconds(3))
                model?.draft = text
                model?.submitDraft()
            }
        }
        // The iPhone app connects here over Wi-Fi (Remote.swift).
        remote = RemoteServer(model: model)
        remote.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        remote?.stop()
        model.shutdown()
    }

    @objc private func pairIPhone() {
        if pairWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 400), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Pair iPhone"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: PairView())
            window.center()
            pairWindow = window
        }
        pairWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // MARK: Window layout

    @objc func layoutFill() { layout(.fill) }
    @objc func layoutLeft() { layout(.left) }
    @objc func layoutRight() { layout(.right) }
    @objc func layoutCenter() { layout(.center) }

    private func layout(_ layout: WindowLayout) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        window.setFrame(layout.frame(in: screen.visibleFrame), display: true, animate: true)
    }

    // MARK: Show / hide

    private func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    private func hide() {
        NSApp.hide(nil)
    }

    // MARK: Keyboard and trackpad

    private func installKeyboard() {
        let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleKey(event) ?? false }
            return handled ? nil : event
        }
        // Three-finger swipe also works if System Settings › Trackpad › "Swipe between pages" uses three fingers.
        let swipes = NSEvent.addLocalMonitorForEvents(matching: .swipe) { [weak self] event in
            MainActor.assumeIsolated {
                guard let model = self?.model, !model.isGrid, model.page == nil, model.draftTabs.isEmpty, !model.paletteOpen else { return }
                if event.deltaX > 0 { model.move(-1) } else if event.deltaX < 0 { model.move(1) }
            }
            return nil
        }
        // Pinch out (fingers together) for the grid overview; pinch in to go back.
        let pinches = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
            MainActor.assumeIsolated { self?.handlePinch(event) }
            return nil
        }
        // Two-finger horizontal scroll drags the carousel; vertical scroll goes to the card's thread.
        let scrolls = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.handleScroll(event) ?? false }
            return consumed ? nil : event
        }
        monitors = [keys as Any, swipes as Any, pinches as Any, scrolls as Any]
    }

    private var horizontalDrag = false
    private var lastDeltaX: CGFloat = 0

    private func handleScroll(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas, !model.isGrid, !model.paletteOpen, model.page == nil, model.draftTabs.isEmpty, !model.cards.isEmpty else { return false }
        if event.phase == .began {
            horizontalDrag = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            lastDeltaX = 0
        }
        // Swallow the momentum that follows a horizontal drag.
        if !event.momentumPhase.isEmpty { return horizontalDrag }
        guard horizontalDrag else { return false }
        switch event.phase {
        case .began, .changed:
            model.drag(by: event.scrollingDeltaX)
            lastDeltaX = event.scrollingDeltaX
        case .ended, .cancelled:
            model.endDrag(velocity: lastDeltaX)
        default:
            break
        }
        return true
    }

    private var pinch: CGFloat = 0

    private func handlePinch(_ event: NSEvent) {
        if event.phase == .began { pinch = 0 }
        pinch += event.magnification
        // Switch as soon as the gesture is clearly one way, so it feels immediate.
        if pinch < -0.12 && !model.isGrid { model.setGrid(true); pinch = -1 }
        if pinch > 0.12 && model.isGrid { model.setGrid(false); pinch = 1 }
    }

    /// Returns true when Relay consumed the key.
    private func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let draftEmpty = model.draft.isEmpty
        let key = Int(event.keyCode)
        // The Save draft prompt is up: Return, Esc and the rest are its buttons.
        if model.savedDraft != nil { return false }
        if flags == .command, event.charactersIgnoringModifiers == "k" { model.togglePalette(); return true }
        if flags == [.command, .option], event.charactersIgnoringModifiers == "w" { model.closeAll(); return true }
        // ⌘Z right after a send takes it back, wherever you are (text-field undo carries on once nothing is held).
        if flags == .command, event.charactersIgnoringModifiers == "z", !model.undoableSends.isEmpty { model.undoSend(); return true }
        if model.page != nil, key == kVK_Escape { model.closePage(); return true }
        if !model.draftTabs.isEmpty, key == kVK_Escape { model.collapseDrafts(); return true }
        // Typing in a draft: arrows and Return belong to the text field, not the carousel.
        if model.editingDraft || !model.draftTabs.isEmpty, flags.isEmpty || flags == .shift { return false }

        if model.paletteOpen {
            switch key {
            case kVK_UpArrow: model.movePalette(-1); return true
            case kVK_DownArrow: model.movePalette(1); return true
            case kVK_Escape:
            if model.cards.isEmpty { hide() } else { model.togglePalette() }
            return true
            default: return false
            }
        }
        if flags == .command, event.charactersIgnoringModifiers == "g" { model.setGrid(!model.isGrid); return true }
        // ⌘V with a screenshot or files on the clipboard: they go in the composer as attachments.
        if flags == .command, event.charactersIgnoringModifiers == "v", model.page == nil, !model.isGrid, !model.editingDraft,
           model.draftTabs.isEmpty, model.pasteIntoComposer() { return true }
        // Typing "@…": the card list above the composer takes ↑ ↓, Tab and Esc.
        if !model.mentionChoices.isEmpty, flags.isEmpty || flags == .shift {
            switch key {
            case kVK_UpArrow: model.moveMention(-1); return true
            case kVK_DownArrow: model.moveMention(1); return true
            case kVK_Tab: model.completeMention(); return true
            case kVK_Escape: model.draft = ""; return true
            default: break
            }
        }
        if key == kVK_Escape, model.dictation.isRecording { model.dictation.stop(); return true }

        if model.isGrid {
            switch key {
            case kVK_LeftArrow where draftEmpty: model.jump(to: model.focusedIndex - 1); return true
            case kVK_RightArrow where draftEmpty: model.jump(to: model.focusedIndex + 1); return true
            case kVK_UpArrow where draftEmpty: model.jump(to: model.focusedIndex - 3); return true
            case kVK_DownArrow where draftEmpty: model.jump(to: model.focusedIndex + 3); return true
            case kVK_Return where draftEmpty, kVK_ANSI_KeypadEnter where draftEmpty:
                if let card = model.focused { model.open(card) }
                return true
            case kVK_Escape: model.setGrid(false); return true
            default: break
            }
        }

        switch key {
        case kVK_LeftArrow where flags == .command || (flags.isEmpty && draftEmpty):
            model.move(-1); return true
        case kVK_RightArrow where flags == .command || (flags.isEmpty && draftEmpty):
            model.move(1); return true
        case kVK_Escape where flags.isEmpty:
            if let card = model.focused, card.running { model.interrupt(card) } else { hide() }
            return true
        default:
            break
        }
        if flags == .command, let chars = event.charactersIgnoringModifiers {
            if let digit = Int(chars), (1...9).contains(digit) { model.jump(to: digit - 1); return true }
            if chars == "n", let card = model.focused { model.newCard(like: card); return true }
            if chars == "w", let card = model.focused { model.close(card); return true }
        }
        return false
    }

    // MARK: Menu (Edit is needed for copy/paste in text fields)

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Pair iPhone…", action: #selector(pairIPhone), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Relay", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Relay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        // Window menu: macOS adds its own Move & Resize items (fn⌃← / fn⌃→ for halves) once this is the windows menu.
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        for (title, selector) in WindowLayout.items { windowMenu.addItem(withTitle: title, action: selector, keyEquivalent: "") }
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = main
    }
}


@main
@MainActor
enum Main {
    static let delegate = AppDelegate()
    static func main() {
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
