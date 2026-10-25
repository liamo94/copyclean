import SwiftUI
import AppKit
import Carbon

@main
struct MangleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var shared: AppDelegate?
    var editorWindow: NSWindow?
    var historyWindow: NSWindow?
    var settingsWindow: NSWindow?
    var hotKeyRef: EventHotKeyRef?
    var historyHotKeyRef: EventHotKeyRef?
    var scratchHotKeyRef: EventHotKeyRef?
    var editorViewModel = EditorViewModel()
    var historyManager = HistoryManager()
    var statusItem: NSStatusItem?
    var eventHandlerInstalled = false
    var historyReturnAction: (() -> Void)?
    var historyCopyAction: (() -> Void)?
    var historyDeleteAction: (() -> Void)?
    var historyFocusSearchAction: (() -> Void)?
    var keyEventMonitor: Any?
    var clipboardChangeCountOnHide: Int = 0
    /// The app that was frontmost when the editor/history opened — Save & Paste returns to it.
    private var previousApp: NSRunningApplication?
    /// Unsaved editor text from the previous run, restored by the next hotkey press when
    /// there's no new selection or clipboard content (same rules as a hidden editor).
    private var pendingDraft: EditorDraft?
    /// Global monitor for the ⌘C ⌘C trigger (see `updateDoubleCopyMonitor`).
    private var doubleCopyMonitor: Any?
    private var lastCopyPress: Date = .distantPast
    /// The editor's frame before presentation mode enlarged it.
    private var frameBeforePresenting: NSRect?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // Two copies (say an Xcode build and the installed app) both receive the global
        // hotkeys, so each would open its own editor. The newest launch takes over — but only
        // once the old copy has exited, so its unsaved draft and history are on disk before
        // we read them and its hotkeys are free to register.
        let others = Bundle.main.bundleIdentifier.map {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
                .filter { $0 != NSRunningApplication.current }
        } ?? []
        guard !others.isEmpty else {
            finishLaunching()
            return
        }
        others.forEach { $0.terminate() }
        let deadline = Date().addingTimeInterval(3)
        func waitForExit() {
            if others.allSatisfy(\.isTerminated) || Date() >= deadline {
                historyManager.reload()
                finishLaunching()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { waitForExit() }
            }
        }
        waitForExit()
    }

    private func finishLaunching() {
        if let draft = EditorDraft.load() {
            pendingDraft = draft
            clipboardChangeCountOnHide = draft.clipboardChangeCount
        }
        
        // Setup settings callback
        SettingsManager.shared.onShortcutsChanged = { [weak self] in
            self?.reregisterHotkeys()
            self?.updateMenuShortcuts()
            self?.updateDoubleCopyMonitor()
        }
        
        // Listen for clear-history requests from Settings UI
        NotificationCenter.default.addObserver(
            self, selector: #selector(clearHistory),
            name: .clearHistory, object: nil
        )
        
        // Register global hotkeys
        registerGlobalHotkey()
        updateDoubleCopyMonitor()
        
        // Create menu bar icon
        setupMenuBar()
        
        // Suppress beep sounds for unhandled keys in history window
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self,
                  self.historyWindow?.isKeyWindow == true else {
                return event
            }
            // Escape or Cmd+W -> close history
            if event.keyCode == 53 ||
                (event.keyCode == 13 && event.modifierFlags.contains(.command)) {
                self.historyWindow?.close()
                self.historyWindow = nil
                return nil
            }
            // Return key -> edit selected entry
            if event.keyCode == 36 {
                self.historyReturnAction?()
                return nil
            }
            // Cmd+C -> copy selected entry and close
            if event.keyCode == 8 && event.modifierFlags.contains(.command) {
                self.historyCopyAction?()
                return nil
            }
            // Cmd+F -> focus search field
            if event.keyCode == 3 && event.modifierFlags.contains(.command) {
                self.historyFocusSearchAction?()
                return nil
            }
            // Allow typing in search field
            if let responder = self.historyWindow?.firstResponder,
               responder is NSTextView {
                return event
            }
            // Delete/Backspace -> delete selected entry (only when not in search field)
            if event.keyCode == 51 {
                self.historyDeleteAction?()
                return nil
            }
            // Allow arrow keys, tab
            let passThroughKeys: Set<UInt16> = [123, 124, 125, 126, 48]
            if passThroughKeys.contains(event.keyCode) {
                return event
            }
            // Swallow everything else silently
            return nil
        }
        
        // Hide editor/history when user switches to another app
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification, object: nil
        )
        
        // Register with macOS Accessibility. The prompt call triggers the OS dialog (which adds Mangle
        // to the Settings list). The AX read attempt below also forces TCC registration even if the
        // dialog is suppressed. Both are safe no-ops when permission is already granted.
        let axOptions = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(axOptions)
        let sysEl = AXUIElementCreateSystemWide()
        var _unused: CFTypeRef?
        AXUIElementCopyAttributeValue(sysEl, kAXFocusedApplicationAttribute as CFString, &_unused)
        
        // Hide dock icon for a cleaner utility app experience
        NSApp.setActivationPolicy(.accessory)
        
    }
    
    func applicationWillTerminate(_ notification: Notification) {
        historyManager.flush()
        saveDraft()
        if let monitor = doubleCopyMonitor {
            NSEvent.removeMonitor(monitor)
            doubleCopyMonitor = nil
        }
        if let monitor = keyEventMonitor {
            NSEvent.removeMonitor(monitor)
            keyEventMonitor = nil
        }
    }
    
    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        
        if let button = statusItem?.button {
            if let img = NSImage(named: "MenuBarIcon") {
                img.isTemplate = true
                img.size = NSSize(width: 18, height: 18)
                button.image = img
            } else {
                button.image = NSImage(systemSymbolName: "curlybraces", accessibilityDescription: "Mangle")
            }
        }
        
        updateMenuShortcuts()
    }
    
    func updateMenuShortcuts() {
        let menu = NSMenu()
        
        let settings = SettingsManager.shared
        
        let editorItem = NSMenuItem(title: "Open Editor", action: #selector(showEditorFromMenu), keyEquivalent: settings.editorShortcut.keyEquivalent)
        editorItem.keyEquivalentModifierMask = settings.editorShortcut.cocoaModifiers
        menu.addItem(editorItem)
        
        let scratchItem = NSMenuItem(title: "New Scratch", action: #selector(showScratch), keyEquivalent: settings.scratchShortcut.keyEquivalent)
        scratchItem.keyEquivalentModifierMask = settings.scratchShortcut.cocoaModifiers
        menu.addItem(scratchItem)
        
        let historyItem = NSMenuItem(title: "Recent Snippets", action: #selector(showHistory), keyEquivalent: settings.historyShortcut.keyEquivalent)
        historyItem.keyEquivalentModifierMask = settings.historyShortcut.cocoaModifiers
        menu.addItem(historyItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    @objc func showEditorFromMenu() {
        rememberFrontmostApp()
        let anchor = visibleWindowFrame()
        closeHistory()
        let text = (AXIsProcessTrusted() ? selectedTextFromFrontmostApp() : nil) ?? NSPasteboard.general.string(forType: .string) ?? ""
        loadEditor(text)
        editorViewModel.sourceEntryID = nil
        presentEditorWindow(replacing: anchor)
    }
    
    // MARK: - Scratch pad
    
    /// The scratch shortcut: brings back an unfinished scratch pad, or opens a blank one.
    /// Pressed while the scratch pad is frontmost, it hides it again.
    @objc func showScratch() {
        let vm = editorViewModel
        if editorWindow?.isKeyWindow == true, vm.isScratch {
            closeEditor()
            return
        }
        rememberFrontmostApp()
        let anchor = visibleWindowFrame()
        closeHistory()
        if editorWindow == nil, let draft = pendingDraft, draft.isScratch == true {
            vm.restore(draft)
            presentEditorWindow(replacing: anchor)
            return
        }
        if editorWindow != nil, vm.isScratch, vm.isDirty {
            restoreHiddenEditor(vm.text, replacing: anchor)
            return
        }
        newScratch(replacing: anchor)
    }
    
    /// Replaces the editor's contents with a blank scratch pad (⌘N), keeping any unsaved
    /// text in history. Opens where the window already is, if one is showing.
    func newScratch(replacing anchor: NSRect? = nil) {
        let anchor = anchor ?? visibleWindowFrame()
        stashEditorText(includingEdits: true)
        editorViewModel.loadScratch()
        presentEditorWindow(replacing: anchor)
    }
    
    /// Loads text into the editor, keeping an unsaved scratch pad it replaces in history.
    private func loadEditor(_ text: String, language: String? = nil) {
        stashEditorText(includingEdits: false)
        editorViewModel.load(text, language: language)
    }
    
    /// Saves unsaved scratch text (and, with `includingEdits`, an unsaved edit of copied
    /// text) to history before it's replaced, so starting something new never loses work.
    private func stashEditorText(includingEdits: Bool) {
        let vm = editorViewModel
        let text: String
        let isScratch: Bool
        if editorWindow == nil, let draft = pendingDraft {
            // Fresh launch: the previous run's draft hasn't been restored into the editor yet.
            guard draft.isScratch == true || includingEdits else { return }
            text = draft.text
            isScratch = draft.isScratch == true
        } else {
            guard vm.isDirty, vm.isScratch || includingEdits else { return }
            text = vm.text
            isScratch = vm.isScratch
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if SettingsManager.shared.pauseHistory {
            showToast("History is paused — previous text not kept")
            return
        }
        historyManager.addEntry(text, isScratch: isScratch)
        showToast(isScratch ? "Scratch saved to History" : "Previous edit saved to History")
    }
    
    // MARK: - Presentation mode
    
    /// Large text and minimal chrome for showing something to others. The window grows to
    /// most of the screen and stays up when another app is clicked.
    func togglePresentation() {
        guard let window = editorWindow else { return }
        if editorViewModel.isPresenting {
            endPresentation(animate: true)
            return
        }
        frameBeforePresenting = window.frame
        editorViewModel.isPresenting = true
        // Normal level so the app being demoed can come in front; the editor stays behind it
        // rather than hiding, and the hotkey brings it back.
        window.level = .normal
        let screen = (window.screen ?? screenAtCursor()).visibleFrame
        let size = NSSize(width: (screen.width * 0.8).rounded(), height: (screen.height * 0.85).rounded())
        let frame = NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2, width: size.width, height: size.height)
        window.setFrame(frame, display: true, animate: true)
    }
    
    private func endPresentation(animate: Bool) {
        guard editorViewModel.isPresenting else { return }
        editorViewModel.isPresenting = false
        editorWindow?.level = .floating
        if let frame = frameBeforePresenting, let window = editorWindow {
            window.setFrame(frame, display: true, animate: animate && window.isVisible)
        }
        frameBeforePresenting = nil
    }
    
    @objc func appDidResignActive() {
        clipboardChangeCountOnHide = NSPasteboard.general.changeCount
        // While presenting, clicking another app (to run a demo) mustn't hide the editor.
        if !editorViewModel.isPresenting { editorWindow?.orderOut(nil) }
        historyWindow?.orderOut(nil)
        saveDraft()
    }
    
    // MARK: - ⌘C ⌘C trigger
    
    /// Installs or removes the global key monitor for ⌘C ⌘C. Global monitors only see
    /// other apps' key events and only receive them once Accessibility access is granted,
    /// which the app already asks for — no extra permission needed.
    func updateDoubleCopyMonitor() {
        let enabled = SettingsManager.shared.doubleCopyOpensEditor
        if enabled, doubleCopyMonitor == nil {
            doubleCopyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleGlobalKeyDown(event)
            }
        } else if !enabled, let monitor = doubleCopyMonitor {
            NSEvent.removeMonitor(monitor)
            doubleCopyMonitor = nil
        }
        // A monitor installed before Accessibility was granted may never receive events;
        // once access arrives, reinstall it.
        if enabled, !AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                if AXIsProcessTrusted() {
                    if let monitor = self.doubleCopyMonitor { NSEvent.removeMonitor(monitor) }
                    self.doubleCopyMonitor = nil
                }
                self.updateDoubleCopyMonitor()
            }
        }
    }
    
    private static let doubleCopyInterval: TimeInterval = 0.4
    
    private func handleGlobalKeyDown(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        // Match the character, not the key code, so ⌘C works on non-QWERTY layouts.
        guard mods == .command, !event.isARepeat,
              event.charactersIgnoringModifiers?.lowercased() == "c" else {
            lastCopyPress = .distantPast
            return
        }
        let now = Date()
        if now.timeIntervalSince(lastCopyPress) <= Self.doubleCopyInterval {
            lastCopyPress = .distantPast   // a third press starts a new pair
            openEditorFromDoubleCopy()
        } else {
            lastCopyPress = now
        }
    }
    
    /// The second ⌘C is still being handled by the source app, so wait (briefly) for the
    /// pasteboard to update before reading it.
    private func openEditorFromDoubleCopy() {
        let pasteboard = NSPasteboard.general
        let changeCountAtPress = pasteboard.changeCount
        let deadline = Date().addingTimeInterval(0.15)
        func finish() {
            guard let text = pasteboard.string(forType: .string), !text.isEmpty else {
                showToast("Nothing to edit — copy some text first")
                return
            }
            rememberFrontmostApp()
            let anchor = visibleWindowFrame()
            closeHistory()
            loadEditor(text)
            editorViewModel.sourceEntryID = nil
            presentEditorWindow(replacing: anchor)
        }
        func poll() {
            if pasteboard.changeCount != changeCountAtPress || Date() >= deadline {
                finish()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { poll() }
            }
        }
        poll()
    }
    
    private func rememberFrontmostApp() {
        if let app = NSWorkspace.shared.frontmostApplication, app != NSRunningApplication.current {
            previousApp = app
        }
    }
    
    /// Persists unsaved editor text so it survives quitting; removes the draft otherwise.
    private func saveDraft() {
        guard pendingDraft == nil else { return }   // previous run's draft not yet restored
        let vm = editorViewModel
        let text = vm.text
        guard editorWindow != nil, vm.isDirty, !text.isEmpty else {
            EditorDraft.clear()
            return
        }
        EditorDraft(
            text: text, baseText: vm.baseText, language: vm.currentLanguage,
            languageIsManual: vm.languageIsManual, sourceEntryID: vm.sourceEntryID,
            clipboardChangeCount: clipboardChangeCountOnHide, isScratch: vm.isScratch
        ).save()
    }
    
    @objc func clearHistory() {
        historyManager.clearHistory()
    }
    
    @objc func showSettings() {
        closeEditor()
        closeHistory()
        
        if let window = settingsWindow {
            // Fresh view each time so edits abandoned with Cancel don't linger in @State.
            window.contentView = NSHostingView(rootView: SettingsView())
            centerWindow(window, on: screenAtCursor())
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            createSettingsWindow()
        }
    }
    
    func createSettingsWindow() {
        let contentView = SettingsView()
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 840),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        
        centerWindow(window, on: screenAtCursor())
        window.title = "Mangle Settings"
        window.contentView = NSHostingView(rootView: contentView)
        window.isReleasedWhenClosed = false
        
        self.settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func registerGlobalHotkey() {
        // Only install the event handler once
        if !eventHandlerInstalled {
            var eventType = EventTypeSpec()
            eventType.eventClass = OSType(kEventClassKeyboard)
            eventType.eventKind = OSType(kEventHotKeyPressed)
            
            InstallEventHandler(
                GetApplicationEventTarget(),
                { (nextHandler, theEvent, userData) -> OSStatus in
                    var hotKeyID = EventHotKeyID()
                    GetEventParameter(theEvent,
                                      EventParamName(kEventParamDirectObject),
                                      EventParamType(typeEventHotKeyID),
                                      nil,
                                      MemoryLayout<EventHotKeyID>.size,
                                      nil,
                                      &hotKeyID)
                    
                    let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
                    
                    if hotKeyID.id == 1 {
                        appDelegate.showEditor()
                    } else if hotKeyID.id == 2 {
                        appDelegate.showHistory()
                    } else if hotKeyID.id == 3 {
                        appDelegate.showScratch()
                    }
                    
                    return noErr
                },
                1,
                &eventType,
                Unmanaged.passUnretained(self).toOpaque(),
                nil
            )
            eventHandlerInstalled = true
        }
        
        registerHotkeys()
    }
    
    func reregisterHotkeys() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
        if let ref = historyHotKeyRef {
            UnregisterEventHotKey(ref)
            historyHotKeyRef = nil
        }
        if let ref = scratchHotKeyRef {
            UnregisterEventHotKey(ref)
            scratchHotKeyRef = nil
        }
        registerHotkeys()
    }
    
    private func registerHotkeys() {
        let settings = SettingsManager.shared
        
        var hotKeyID1 = EventHotKeyID()
        hotKeyID1.signature = OSType("QEDT".fourCharCodeValue)
        hotKeyID1.id = 1
        let status1 = RegisterEventHotKey(settings.editorShortcut.keyCode, settings.editorShortcut.modifiers, hotKeyID1, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status1 != noErr {
            DispatchQueue.main.async { self.showToast("⚠️ Quick Edit shortcut conflict") }
        }
        
        var hotKeyID2 = EventHotKeyID()
        hotKeyID2.signature = OSType("HIST".fourCharCodeValue)
        hotKeyID2.id = 2
        let status2 = RegisterEventHotKey(settings.historyShortcut.keyCode, settings.historyShortcut.modifiers, hotKeyID2, GetApplicationEventTarget(), 0, &historyHotKeyRef)
        if status2 != noErr {
            DispatchQueue.main.async { self.showToast("⚠️ Show History shortcut conflict") }
        }
        
        var hotKeyID3 = EventHotKeyID()
        hotKeyID3.signature = OSType("SCRT".fourCharCodeValue)
        hotKeyID3.id = 3
        let status3 = RegisterEventHotKey(settings.scratchShortcut.keyCode, settings.scratchShortcut.modifiers, hotKeyID3, GetApplicationEventTarget(), 0, &scratchHotKeyRef)
        if status3 != noErr {
            DispatchQueue.main.async { self.showToast("⚠️ New Scratch shortcut conflict") }
        }
    }
    
    @objc func showHistory() {
        rememberFrontmostApp()
        closeSettings()
        
        // Leave presentation first, so history takes the editor's normal frame, not the
        // enlarged one — and a hidden editor isn't left in presentation mode.
        endPresentation(animate: false)
        
        // If we have a preserved history window (user was editing a history entry),
        // restore it rather than starting fresh
        let anchor = visibleWindowFrame()
        if let hw = historyWindow {
            editorWindow?.orderOut(nil)
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            hw.makeKeyAndOrderFront(nil)
            if let anchor { place(hw, replacing: anchor) }
            return
        }
        
        closeEditor()
        createHistoryWindow(replacing: anchor)
    }
    
    func createHistoryWindow(replacing anchor: NSRect? = nil) {
        let contentView = HistoryView(
            historyManager: historyManager,
            onSelectEntry: { [weak self] entry in
                self?.loadEntryToEditor(entry)
            },
            onClose: { [weak self] in
                self?.closeHistory()
            }
        )
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        place(window, replacing: anchor)
        window.title = "Recent Snippets"
        window.identifier = NSUserInterfaceItemIdentifier("history")
        window.contentView = NSHostingView(rootView: contentView)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 400)
        
        self.historyWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        // Focus the list so first entry is highlighted. Force layout so the SwiftUI List's
        // table exists now; fall back to the next run loop turn if it still doesn't.
        window.contentView?.layoutSubtreeIfNeeded()
        if let tableView = findTableView(in: window.contentView) {
            window.makeFirstResponder(tableView)
        } else {
            DispatchQueue.main.async {
                if let tableView = self.findTableView(in: window.contentView) {
                    window.makeFirstResponder(tableView)
                }
            }
        }
    }
    
    func findSubview<T: NSView>(ofType type: T.Type, in view: NSView?) -> T? {
        guard let view = view else { return nil }
        if let match = view as? T { return match }
        for subview in view.subviews {
            if let found = findSubview(ofType: type, in: subview) {
                return found
            }
        }
        return nil
    }
    
    func findTableView(in view: NSView?) -> NSTableView? {
        findSubview(ofType: NSTableView.self, in: view)
    }
    
    func findTextView(in view: NSView?) -> NSTextView? {
        findSubview(ofType: NSTextView.self, in: view)
    }
    
    func loadEntryToEditor(_ entry: HistoryEntry) {
        loadEditor(entry.text, language: entry.language)
        editorViewModel.sourceEntryID = entry.id
        // Hide but don't destroy — closing the editor returns here
        let anchor = historyWindow?.frame
        historyWindow?.orderOut(nil)
        presentEditorWindow(replacing: anchor)
    }
    
    func closeHistory() {
        historyWindow?.close()
        historyWindow = nil
        historyReturnAction = nil
        historyCopyAction = nil
        historyDeleteAction = nil
    }
    
    func showEditor() {
        // If our editor is already key window, don't reload — just focus it
        if editorWindow?.isKeyWindow == true {
            return
        }
        rememberFrontmostApp()
        let anchor = visibleWindowFrame()
        
        // If we were editing a history entry, restore the editor for that entry
        if historyWindow != nil && editorViewModel.sourceEntryID != nil {
            historyWindow?.orderOut(nil)
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            editorWindow?.makeKeyAndOrderFront(nil)
            if let anchor, let window = editorWindow { place(window, replacing: anchor) }
            return
        }
        
        // If history is open (fresh, no entry being edited), close it and open editor from clipboard
        if historyWindow != nil {
            closeHistory()
            loadEditor(NSPasteboard.general.string(forType: .string) ?? "")
            presentEditorWindow(replacing: anchor)
            return
        }
        
        // Snapshot whether the editor has hidden unsaved content worth restoring
        let hiddenContent = editorWindow == nil
            ? pendingDraft?.text
            : (editorWindow?.isVisible == false && !editorViewModel.text.isEmpty) ? editorViewModel.text : nil
        
        // Try AX first — instant, no side effects
        if AXIsProcessTrusted(), let selected = selectedTextFromFrontmostApp(), !selected.isEmpty {
            loadEditor(selected)
            presentEditorWindow(replacing: anchor)
            return
        }
        
        // Without AX permission, use clipboard directly (restore if nothing new)
        guard AXIsProcessTrusted() else {
            let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
            if let old = hiddenContent, NSPasteboard.general.changeCount == clipboardChangeCountOnHide {
                restoreHiddenEditor(old, replacing: anchor)
            } else {
                loadEditor(clipboard)
                presentEditorWindow(replacing: anchor)
            }
            return
        }
        
        // Simulate Cmd+C — this also catches selections in apps that don't expose AX text
        let pasteboard = NSPasteboard.general
        let previousText = pasteboard.string(forType: .string) ?? ""
        let savedChangeCount = pasteboard.changeCount
        
        let src = CGEventSource(stateID: .hidSystemState)
        let dn = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true)
        dn?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false)
        up?.flags = .maskCommand
        dn?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        
        // Poll for the copy to land instead of always waiting the full timeout — most apps
        // write the pasteboard within a few ms, so the editor appears almost immediately.
        let deadline = Date().addingTimeInterval(0.15)
        func finish() {
            let newText = pasteboard.string(forType: .string) ?? ""
            let gotNewText = pasteboard.changeCount != savedChangeCount && !newText.isEmpty && newText != previousText
            if let old = hiddenContent, !gotNewText {
                // Nothing new from Cmd+C either — restore unsaved content
                restoreHiddenEditor(old, replacing: anchor)
            } else {
                loadEditor(gotNewText ? newText : previousText)
                presentEditorWindow(replacing: anchor)
            }
        }
        func poll() {
            // Some apps clear the pasteboard and write the text a moment later, so wait until
            // there's actually a string, not just a changeCount bump.
            let copied = pasteboard.changeCount != savedChangeCount && pasteboard.string(forType: .string) != nil
            if copied || Date() >= deadline {
                finish()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { poll() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { poll() }
    }
    
    /// Reads the selected text from the currently frontmost app via the Accessibility API.
    /// Returns nil if permission hasn't been granted or nothing is selected.
    private func selectedTextFromFrontmostApp() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        // AX calls block until the target app answers; a hung app (common with Electron)
        // would otherwise stall the hotkey for the default ~6s timeout.
        AXUIElementSetMessagingTimeout(axApp, 0.25)
        var focusedEl: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedEl) == .success,
              let el = focusedEl else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
    
    /// Shows the editor in place of `anchor` (the frame of a Mangle window that was on
    /// screen), or near the cursor when nothing was showing.
    private func presentEditorWindow(replacing anchor: NSRect? = nil) {
        closeSettings()
        
        if let window = editorWindow {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            window.makeKeyAndOrderFront(nil)
            // Position after makeKeyAndOrderFront so our placement overrides any macOS window restoration
            if !editorViewModel.isPresenting { place(window, replacing: anchor) }
        } else {
            createEditorWindow(replacing: anchor)
        }
        focusEditorTextView()
        // Anything shown now supersedes a draft from the previous run.
        if pendingDraft != nil {
            pendingDraft = nil
            EditorDraft.clear()
        }
    }
    
    /// Make the text view first responder right away so the first keystrokes aren't lost.
    /// On first creation the SwiftUI hierarchy may not be built yet, so force a layout pass.
    private func focusEditorTextView() {
        guard let window = editorWindow else { return }
        if editorViewModel.textView == nil { window.contentView?.layoutSubtreeIfNeeded() }
        if let textView = editorViewModel.textView ?? findTextView(in: window.contentView) {
            window.makeFirstResponder(textView)
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self, let textView = self.editorViewModel.textView ?? self.findTextView(in: window.contentView) else { return }
                window.makeFirstResponder(textView)
            }
        }
    }
    
    func createEditorWindow(replacing anchor: NSRect? = nil) {
        let contentView = EditorView(viewModel: editorViewModel, onSave: { [weak self] in
            self?.saveToClipboard()
        }, onSaveAndPaste: { [weak self] in
            self?.saveAndPaste()
        }, onClose: { [weak self] in
            self?.closeEditor()
        }, onNewScratch: { [weak self] in
            self?.newScratch()
        }, onTogglePresentation: { [weak self] in
            self?.togglePresentation()
        })
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        place(window, replacing: anchor)
        window.title = "Mangle"
        window.contentView = NSHostingView(rootView: contentView)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.collectionBehavior = [.moveToActiveSpace]
        
        self.editorWindow = window
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        window.makeKeyAndOrderFront(nil)
    }
    
    /// Copies, closes, then switches back to the app the text came from and pastes it there.
    func saveAndPaste() {
        let target = previousApp
        saveToClipboard(toast: nil)
        guard let target, !target.isTerminated else {
            showToast("Copied to clipboard")
            return
        }
        guard AXIsProcessTrusted() else {
            showToast("Copied — enable Accessibility to paste automatically")
            return
        }
        target.activate()
        // Wait for the target to actually become frontmost before sending ⌘V, or the
        // keystroke can land in the wrong app.
        let deadline = Date().addingTimeInterval(1.0)
        func attempt() {
            if NSWorkspace.shared.frontmostApplication == target {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    let src = CGEventSource(stateID: .hidSystemState)
                    let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
                    down?.flags = .maskCommand
                    let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
                    up?.flags = .maskCommand
                    down?.post(tap: .cghidEventTap)
                    up?.post(tap: .cghidEventTap)
                    self?.showToast("Pasted")
                }
            } else if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { attempt() }
            } else {
                showToast("Copied to clipboard")
            }
        }
        attempt()
    }
    
    func saveToClipboard(toast: String? = "Copied to clipboard") {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(editorViewModel.text, forType: .string)
        
        // Persist manually-set language back to the source history entry
        if let sourceID = editorViewModel.sourceEntryID, editorViewModel.languageIsManual {
            historyManager.updateLanguage(for: sourceID, language: editorViewModel.currentLanguage)
        }
        
        // Save to history (unless paused)
        if !SettingsManager.shared.pauseHistory {
            historyManager.addEntry(editorViewModel.text, isScratch: editorViewModel.isScratch)
        }
        
        editorViewModel.sourceEntryID = nil
        editorViewModel.markSaved()
        closeHistory()
        closeEditor()
        EditorDraft.clear()
        if let toast { showToast(toast) }
    }
    
    private func screenAtCursor() -> NSScreen {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) ?? NSScreen.main ?? NSScreen.screens[0]
    }
    
    private func centerWindow(_ window: NSWindow, on screen: NSScreen) {
        let sf = screen.visibleFrame
        let wf = window.frame
        window.setFrameOrigin(NSPoint(x: sf.midX - wf.width / 2, y: sf.midY - wf.height / 2))
    }
    
    /// The frame of whichever editor/history window is on screen, so the next one can open
    /// in its place instead of jumping to the cursor.
    private func visibleWindowFrame() -> NSRect? {
        [editorWindow, historyWindow].compactMap { $0 }.first { $0.isVisible }?.frame
    }
    
    /// Puts `window` where `anchor` was (top-left corners aligned, since the windows differ
    /// in size), or near the cursor when there's no anchor.
    private func place(_ window: NSWindow, replacing anchor: NSRect?) {
        guard let anchor else {
            positionWindowNearCursor(window)
            return
        }
        guard anchor != window.frame else { return }
        window.setFrameTopLeftPoint(NSPoint(x: anchor.minX, y: anchor.maxY))
    }
    
    private func positionWindowNearCursor(_ window: NSWindow) {
        let screen = screenAtCursor()
        let cursor = NSEvent.mouseLocation
        let sf = screen.visibleFrame
        let wf = window.frame
        let x = max(sf.minX, min(cursor.x - wf.width / 2,  sf.maxX - wf.width))
        let y = max(sf.minY, min(cursor.y - wf.height / 2, sf.maxY - wf.height))
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
    
    func showToast(_ message: String) {
        // Always defer to next run loop so we never trigger NSPanel constraint
        // loops when called from inside a SwiftUI layout pass or button action.
        DispatchQueue.main.async { self._showToast(message) }
    }
    
    private func _showToast(_ message: String) {
        let screen = screenAtCursor()
        
        // Pure AppKit toast — avoids NSHostingView constraint loops in borderless panels.
        let hPad: CGFloat = 12
        let vPad: CGFloat = 6
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        
        // Measure text
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: AppTheme.onTeal]
        let textSize = (message as NSString).size(withAttributes: attrs)
        let width  = ceil(textSize.width)  + hPad * 2
        let height = ceil(textSize.height) + vPad * 2
        
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        // Layer-backed container with rounded rect background
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(red: 0.20, green: 0.78, blue: 0.60, alpha: 0.95).cgColor
        container.layer?.cornerRadius = 7
        container.layer?.shadowColor = NSColor.black.withAlphaComponent(0.2).cgColor
        container.layer?.shadowOpacity = 1
        container.layer?.shadowRadius = 4
        container.layer?.shadowOffset = CGSize(width: 0, height: -2)
        
        // Label — no autolayout, plain frame
        let label = NSTextField(frame: NSRect(x: hPad, y: vPad, width: ceil(textSize.width), height: ceil(textSize.height)))
        label.stringValue = message
        label.font = font
        label.textColor = AppTheme.onTeal
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.cell?.wraps = false
        label.cell?.truncatesLastVisibleLine = false
        container.addSubview(label)
        
        panel.contentView = container
        
        // Top-right of the editor/history window while one is showing (below its title
        // bar); top-right of the screen otherwise, e.g. after Save has closed the editor.
        let x: CGFloat
        let y: CGFloat
        if let window = [editorWindow, historyWindow].compactMap({ $0 }).first(where: { $0.isVisible }) {
            let margin: CGFloat = 12
            let contentTop = window.frame.minY + window.contentLayoutRect.maxY
            x = window.frame.maxX - width - margin
            y = contentTop - height - margin
        } else {
            let margin: CGFloat = 16
            x = screen.visibleFrame.maxX - width  - margin
            y = screen.visibleFrame.maxY - height - margin
        }
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        
        panel.alphaValue = 0
        panel.orderFront(nil)
        
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.3
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.close()
            })
        }
    }
    
    /// Re-show the hidden editor as-is. It still holds the unsaved text, so there's nothing to
    /// reload — reloading used to reset the dirty baseline, cursor position and undo history.
    private func restoreHiddenEditor(_ text: String, replacing anchor: NSRect? = nil) {
        guard let window = editorWindow else {
            // Fresh launch: restore the previous run's unsaved draft.
            if let draft = pendingDraft {
                editorViewModel.restore(draft)
                presentEditorWindow(replacing: anchor)
            }
            return
        }
        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        window.makeKeyAndOrderFront(nil)
        if !editorViewModel.isPresenting { place(window, replacing: anchor) }
        focusEditorTextView()
    }
    
    func closeEditor() {
        endPresentation(animate: false)
        let anchor = editorWindow?.isVisible == true ? editorWindow?.frame : nil
        editorWindow?.orderOut(nil)
        // Cancelling an edit ends the history→editor context, so clear the source reference.
        // This ensures the next editor open is treated as fresh (cursor-positioned) rather
        // than a restore, even if historyWindow is still alive but hidden.
        editorViewModel.sourceEntryID = nil
        if let hw = historyWindow {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            hw.makeKeyAndOrderFront(nil)
            // Back to history in the editor's place, in case the editor was moved.
            if let anchor { place(hw, replacing: anchor) }
        }
    }
    
    func closeSettings() {
        settingsWindow?.close()
    }
}

// Helper extension for FourCharCode
extension String {
    var fourCharCodeValue: FourCharCode {
        var result: FourCharCode = 0
        for char in self.utf8 {
            result = (result << 8) + FourCharCode(char)
        }
        return result
    }
}
