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
    var editorViewModel = EditorViewModel()
    var historyManager = HistoryManager()
    var statusItem: NSStatusItem?
    var eventHandlerInstalled = false
    var historyReturnAction: (() -> Void)?
    var historyCopyAction: (() -> Void)?
    var historyDeleteAction: (() -> Void)?
    var historyFocusSearchAction: (() -> Void)?
    var keyEventMonitor: Any?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        
        // Setup settings callback
        SettingsManager.shared.onShortcutsChanged = { [weak self] in
            self?.reregisterHotkeys()
            self?.updateMenuShortcuts()
        }
        
        // Listen for clear-history requests from Settings UI
        NotificationCenter.default.addObserver(
            self, selector: #selector(clearHistory),
            name: .clearHistory, object: nil
        )
        
        // Register global hotkeys
        registerGlobalHotkey()
        
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
        
        // Hide dock icon for a cleaner utility app experience
        NSApp.setActivationPolicy(.accessory)
        
    }
    
    func applicationWillTerminate(_ notification: Notification) {
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
        let text = selectedTextFromFrontmostApp() ?? NSPasteboard.general.string(forType: .string) ?? ""
        editorViewModel.load(text)
        editorViewModel.sourceEntryID = nil
        editorViewModel.languageIsManual = false
        presentEditorWindow()
    }
    
    @objc func clearHistory() {
        historyManager.clearHistory()
    }
    
    @objc func showSettings() {
        closeEditor()
        closeHistory()
        
        if let window = settingsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            createSettingsWindow()
        }
    }
    
    func createSettingsWindow() {
        let contentView = SettingsView()
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        
        window.center()
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
    }
    
    @objc func showHistory() {
        closeEditor()
        closeSettings()
        
        historyWindow?.close()
        historyWindow = nil
        createHistoryWindow()
    }
    
    func createHistoryWindow() {
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
        
        window.center()
        window.title = "Recent Snippets"
        window.identifier = NSUserInterfaceItemIdentifier("history")
        window.contentView = NSHostingView(rootView: contentView)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 600, height: 400)
        
        self.historyWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        
        // Focus the list so first entry is highlighted
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let tableView = self.findTableView(in: window.contentView) {
                window.makeFirstResponder(tableView)
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
        editorViewModel.load(entry.text)
        editorViewModel.sourceEntryID = entry.id
        editorViewModel.languageIsManual = entry.language != nil
        if let lang = entry.language {
            editorViewModel.currentLanguage = lang
        }
        closeHistory()
        presentEditorWindow()
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
        
        // If history is open, skip selection detection to avoid interfering with it
        if historyWindow != nil {
            editorViewModel.load(NSPasteboard.general.string(forType: .string) ?? "")
            presentEditorWindow()
            return
        }
        
        // Try Accessibility API first — reads selected text without a Cmd+C simulation
        if let selected = selectedTextFromFrontmostApp(), !selected.isEmpty {
            editorViewModel.load(selected)
            presentEditorWindow()
            return
        }
        
        // Fallback: simulate Cmd+C and wait for the clipboard to change
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
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self = self else { return }
            let newText = pasteboard.string(forType: .string) ?? ""
            // Use the new clipboard only if Cmd+C actually copied something new
            let text = (pasteboard.changeCount != savedChangeCount && !newText.isEmpty && newText != previousText)
            ? newText
            : previousText
            self.editorViewModel.load(text)
            self.presentEditorWindow()
        }
    }
    
    /// Reads the selected text from the currently frontmost app via the Accessibility API.
    /// Returns nil if permission hasn't been granted or nothing is selected.
    private func selectedTextFromFrontmostApp() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var focusedEl: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedUIElementAttribute as CFString, &focusedEl) == .success,
              let el = focusedEl else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el as! AXUIElement, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
    
    private func presentEditorWindow() {
        closeHistory()
        closeSettings()
        
        if let window = editorWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            createEditorWindow()
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if let window = self.editorWindow,
               let textView = self.findTextView(in: window.contentView) {
                window.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            }
        }
    }
    
    func createEditorWindow() {
        let contentView = EditorView(viewModel: editorViewModel, onSave: { [weak self] in
            self?.saveToClipboard()
        }, onClose: { [weak self] in
            self?.closeEditor()
        })
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.center()
        window.title = "Mangle"
        window.contentView = NSHostingView(rootView: contentView)
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        
        self.editorWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func saveToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(editorViewModel.text, forType: .string)
        
        // Persist manually-set language back to the source history entry
        if let sourceID = editorViewModel.sourceEntryID, editorViewModel.languageIsManual {
            historyManager.updateLanguage(for: sourceID, language: editorViewModel.currentLanguage)
        }
        
        // Save to history (unless paused)
        if !SettingsManager.shared.pauseHistory {
            historyManager.addEntry(editorViewModel.text)
        }
        
        editorViewModel.sourceEntryID = nil
        editorViewModel.markSaved()
        closeEditor()
        showToast("Copied to clipboard")
    }
    
    func showToast(_ message: String) {
        // Always defer to next run loop so we never trigger NSPanel constraint
        // loops when called from inside a SwiftUI layout pass or button action.
        DispatchQueue.main.async { self._showToast(message) }
    }
    
    private func _showToast(_ message: String) {
        guard let screen = NSScreen.main else { return }
        
        // Pure AppKit toast — avoids NSHostingView constraint loops in borderless panels.
        let hPad: CGFloat = 12
        let vPad: CGFloat = 6
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        
        // Measure text
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
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
        label.textColor = .white
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.cell?.wraps = false
        label.cell?.truncatesLastVisibleLine = false
        container.addSubview(label)
        
        panel.contentView = container
        
        // Position top-right with margin
        let margin: CGFloat = 16
        let x = screen.visibleFrame.maxX - width  - margin
        let y = screen.visibleFrame.maxY - height - margin
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
    
    func closeEditor() {
        editorWindow?.orderOut(nil)
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
