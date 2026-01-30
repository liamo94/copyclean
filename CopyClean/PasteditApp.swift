import SwiftUI
import AppKit
import Carbon

@main
struct CopyCleanApp: App {
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
            // Escape -> close history
            if event.keyCode == 53 {
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
            button.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: "Copy Clean")
        }
        
        updateMenuShortcuts()
    }
    
    func updateMenuShortcuts() {
        let menu = NSMenu()
        
        let settings = SettingsManager.shared
        
        let historyItem = NSMenuItem(title: "Show History", action: #selector(showHistory), keyEquivalent: settings.historyShortcut.keyEquivalent)
        historyItem.keyEquivalentModifierMask = settings.historyShortcut.cocoaModifiers
        menu.addItem(historyItem)
        
        let editorItem = NSMenuItem(title: "Quick Edit", action: #selector(showEditorFromMenu), keyEquivalent: settings.editorShortcut.keyEquivalent)
        editorItem.keyEquivalentModifierMask = settings.editorShortcut.cocoaModifiers
        menu.addItem(editorItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        
        statusItem?.menu = menu
    }
    
    @objc func showEditorFromMenu() {
        editorViewModel.text = NSPasteboard.general.string(forType: .string) ?? ""
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
            contentRect: NSRect(x: 0, y: 0, width: 350, height: 250),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        
        window.center()
        window.title = "Copy Clean Settings"
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
        RegisterEventHotKey(settings.editorShortcut.keyCode, settings.editorShortcut.modifiers, hotKeyID1, GetApplicationEventTarget(), 0, &hotKeyRef)
        
        var hotKeyID2 = EventHotKeyID()
        hotKeyID2.signature = OSType("HIST".fourCharCodeValue)
        hotKeyID2.id = 2
        RegisterEventHotKey(settings.historyShortcut.keyCode, settings.historyShortcut.modifiers, hotKeyID2, GetApplicationEventTarget(), 0, &historyHotKeyRef)
    }
    
    @objc func showHistory() {
        closeEditor()
        
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
        window.title = "Copy Clean History"
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
        editorViewModel.text = entry.text
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
        // If our editor is already key window, just use current clipboard
        if editorWindow?.isKeyWindow == true {
            editorViewModel.text = NSPasteboard.general.string(forType: .string) ?? ""
            presentEditorWindow()
            return
        }
        
        let pasteboard = NSPasteboard.general
        let savedChangeCount = pasteboard.changeCount
        
        // Simulate Cmd+C to copy selected text from the frontmost app
        let source = CGEventSource(stateID: .hidSystemState)
        let eventDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true)
        eventDown?.flags = .maskCommand
        let eventUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        eventUp?.flags = .maskCommand
        
        eventDown?.post(tap: .cghidEventTap)
        eventUp?.post(tap: .cghidEventTap)
        
        // Wait for the copy to complete without blocking the main thread
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self = self else { return }
            
            if pasteboard.changeCount != savedChangeCount,
               let newText = pasteboard.string(forType: .string), !newText.isEmpty {
                self.editorViewModel.text = newText
            } else {
                self.editorViewModel.text = pasteboard.string(forType: .string) ?? ""
            }
            
            self.presentEditorWindow()
        }
    }
    
    private func presentEditorWindow() {
        closeHistory()
        
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
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.center()
        window.title = "Copy Clean"
        window.contentView = NSHostingView(rootView: contentView)
        window.level = .floating
        window.isReleasedWhenClosed = false
        
        self.editorWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func saveToClipboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(editorViewModel.text, forType: .string)
        
        // Save to history (unless paused)
        if !SettingsManager.shared.pauseHistory {
            historyManager.addEntry(editorViewModel.text)
        }
        
        closeEditor()
    }
    
    func closeEditor() {
        editorWindow?.orderOut(nil)
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
