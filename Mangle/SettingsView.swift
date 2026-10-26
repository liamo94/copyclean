import SwiftUI
import Carbon
import Combine
import ServiceManagement
import Highlightr

// Shortcut configuration
struct KeyboardShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    
    var displayString: String {
        var parts: [String] = []
        
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        
        if let keyString = keyCodeToString(keyCode) {
            parts.append(keyString)
        }
        
        return parts.joined()
    }
    
    /// Lowercase character for use with NSMenuItem.keyEquivalent
    var keyEquivalent: String {
        keyCodeToString(keyCode)?.lowercased() ?? ""
    }
    
    /// NSEvent modifier flags for use with NSMenuItem.keyEquivalentModifierMask
    var cocoaModifiers: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }
    
    private func keyCodeToString(_ keyCode: UInt32) -> String? {
        let keyMap: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 50: "`", 65: ".", 67: "*", 69: "+",
            71: "Clear", 75: "/", 76: "Enter", 78: "-", 81: "=",
            82: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5",
            88: "6", 89: "7", 91: "8", 92: "9",
            36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8",
            101: "F9", 103: "F11", 105: "F13", 107: "F14", 109: "F10",
            111: "F12", 113: "F15", 118: "F4", 119: "F2", 120: "F1",
            121: "F16", 122: "F17", 123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        return keyMap[keyCode]
    }
}

class SettingsManager: ObservableObject {
    static let shared = SettingsManager()
    
    @Published var editorShortcut: KeyboardShortcut
    @Published var historyShortcut: KeyboardShortcut
    @Published var scratchShortcut: KeyboardShortcut
    @Published var fontSize: CGFloat {
        didSet {
            UserDefaults.standard.set(Double(fontSize), forKey: fontSizeKey)
        }
    }
    /// Font size while presenting — zooming in presentation mode changes this, not `fontSize`.
    @Published var presentationFontSize: CGFloat {
        didSet {
            UserDefaults.standard.set(Double(presentationFontSize), forKey: presentationFontSizeKey)
        }
    }
    /// Presentation mode switches to an accessible high-contrast syntax theme.
    @Published var presentationHighContrast: Bool {
        didSet {
            UserDefaults.standard.set(presentationHighContrast, forKey: presentationHighContrastKey)
        }
    }
    /// Line numbers stay visible while presenting (off by default, for a cleaner slide).
    @Published var presentationLineNumbers: Bool {
        didSet {
            UserDefaults.standard.set(presentationLineNumbers, forKey: presentationLineNumbersKey)
        }
    }
    @Published var pauseHistory: Bool {
        didSet {
            UserDefaults.standard.set(pauseHistory, forKey: pauseHistoryKey)
        }
    }
    @Published var maxHistory: Int {
        didSet {
            UserDefaults.standard.set(maxHistory, forKey: maxHistoryKey)
        }
    }
    @Published var tabSize: Int {
        didSet {
            UserDefaults.standard.set(tabSize, forKey: tabSizeKey)
        }
    }
    @Published var wordWrap: Bool {
        didSet {
            UserDefaults.standard.set(wordWrap, forKey: wordWrapKey)
        }
    }
    @Published var editorFont: EditorFont {
        didSet {
            UserDefaults.standard.set(editorFont.rawValue, forKey: editorFontKey)
        }
    }
    /// Default indentation for documents whose own indentation can't be detected.
    @Published var useTabs: Bool {
        didSet {
            UserDefaults.standard.set(useTabs, forKey: useTabsKey)
        }
    }
    /// Pressing ⌘C twice quickly in any app opens the editor with what was copied.
    @Published var doubleCopyOpensEditor: Bool {
        didSet {
            UserDefaults.standard.set(doubleCopyOpensEditor, forKey: doubleCopyKey)
        }
    }
    @Published var darkTheme: String {
        didSet {
            UserDefaults.standard.set(darkTheme, forKey: darkThemeKey)
        }
    }
    @Published var lightTheme: String {
        didSet {
            UserDefaults.standard.set(lightTheme, forKey: lightThemeKey)
        }
    }
    
    static let defaultDarkTheme = "atom-one-dark"
    static let defaultLightTheme = "xcode"
    static let defaultPresentationFontSize: CGFloat = 24
    static let presentationFontSizeRange: ClosedRange<CGFloat> = 14...72
    
    func themeName(isDark: Bool, presenting: Bool = false) -> String {
        if presenting, presentationHighContrast {
            let name = isDark ? "a11y-dark" : "a11y-light"
            if ThemeCatalog.names.contains(name) { return name }
        }
        return isDark ? darkTheme : lightTheme
    }

    var onShortcutsChanged: (() -> Void)?

    private let editorKey = "EditorShortcut"
    private let historyKey = "HistoryShortcut"
    private let scratchKey = "ScratchShortcut"
    private let presentationFontSizeKey = "PresentationFontSize"
    private let presentationHighContrastKey = "PresentationHighContrast"
    private let presentationLineNumbersKey = "PresentationLineNumbers"
    private let pauseHistoryKey = "PauseHistory"
    private let fontSizeKey = "EditorFontSize"
    private let maxHistoryKey = "MaxHistory"
    private let tabSizeKey = "TabSize"
    private let wordWrapKey = "WordWrap"
    private let editorFontKey = "EditorFontName"
    private let useTabsKey = "UseTabs"
    private let doubleCopyKey = "DoubleCopyOpensEditor"
    private let darkThemeKey = "DarkTheme"
    private let lightThemeKey = "LightTheme"

    init() {
        // Default: Ctrl+Cmd+E for editor
        let defaultEditor = KeyboardShortcut(keyCode: 14, modifiers: UInt32(controlKey | cmdKey))
        // Default: Ctrl+Cmd+H for history
        let defaultHistory = KeyboardShortcut(keyCode: 4, modifiers: UInt32(controlKey | cmdKey))
        // Default: Ctrl+Cmd+N for a new scratch pad
        let defaultScratch = KeyboardShortcut(keyCode: 45, modifiers: UInt32(controlKey | cmdKey))
        
        if let data = UserDefaults.standard.data(forKey: editorKey),
           let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            editorShortcut = shortcut
        } else {
            editorShortcut = defaultEditor
        }
        
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            historyShortcut = shortcut
        } else {
            historyShortcut = defaultHistory
        }
        
        if let data = UserDefaults.standard.data(forKey: scratchKey),
           let shortcut = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) {
            scratchShortcut = shortcut
        } else {
            scratchShortcut = defaultScratch
        }
        
        pauseHistory = UserDefaults.standard.bool(forKey: pauseHistoryKey)
        
        let storedFontSize = UserDefaults.standard.double(forKey: fontSizeKey)
        fontSize = storedFontSize > 0 ? CGFloat(storedFontSize) : NSFont.systemFontSize
        let storedPresentationSize = UserDefaults.standard.double(forKey: presentationFontSizeKey)
        presentationFontSize = storedPresentationSize > 0 ? CGFloat(storedPresentationSize) : Self.defaultPresentationFontSize
        presentationHighContrast = UserDefaults.standard.object(forKey: presentationHighContrastKey) as? Bool ?? true
        presentationLineNumbers = UserDefaults.standard.bool(forKey: presentationLineNumbersKey)
        
        let storedMax = UserDefaults.standard.integer(forKey: "MaxHistory")
        maxHistory = storedMax > 0 ? storedMax : 100
        
        let storedTabSize = UserDefaults.standard.integer(forKey: "TabSize")
        tabSize = storedTabSize > 0 ? storedTabSize : 4

        wordWrap = UserDefaults.standard.object(forKey: "WordWrap") as? Bool ?? true

        let storedFontName = UserDefaults.standard.string(forKey: "EditorFontName")
        editorFont = storedFontName.flatMap(EditorFont.init(rawValue:)) ?? .system
        
        useTabs = UserDefaults.standard.bool(forKey: "UseTabs")
        doubleCopyOpensEditor = UserDefaults.standard.object(forKey: "DoubleCopyOpensEditor") as? Bool ?? true
        darkTheme = UserDefaults.standard.string(forKey: "DarkTheme") ?? Self.defaultDarkTheme
        lightTheme = UserDefaults.standard.string(forKey: "LightTheme") ?? Self.defaultLightTheme
    }
    
    func save() {
        if let data = try? JSONEncoder().encode(editorShortcut) {
            UserDefaults.standard.set(data, forKey: editorKey)
        }
        if let data = try? JSONEncoder().encode(historyShortcut) {
            UserDefaults.standard.set(data, forKey: historyKey)
        }
        if let data = try? JSONEncoder().encode(scratchShortcut) {
            UserDefaults.standard.set(data, forKey: scratchKey)
        }
        onShortcutsChanged?()
    }
}

struct ShortcutRecorder: View {
    let title: String
    @Binding var shortcut: KeyboardShortcut
    @State private var isRecording = false
    
    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button(action: { isRecording = true }) {
                Text(isRecording ? "Press shortcut..." : shortcut.displayString)
                    .frame(minWidth: 100)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .background(
                ShortcutCaptureView(isRecording: $isRecording, shortcut: $shortcut)
            )
        }
    }
}

// NSView wrapper to capture key events
struct ShortcutCaptureView: NSViewRepresentable {
    @Binding var isRecording: Bool
    @Binding var shortcut: KeyboardShortcut
    
    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        view.onShortcutCaptured = { keyCode, modifiers in
            shortcut = KeyboardShortcut(keyCode: keyCode, modifiers: modifiers)
            isRecording = false
        }
        view.onCancel = {
            isRecording = false
        }
        return view
    }
    
    func updateNSView(_ nsView: ShortcutCaptureNSView, context: Context) {
        if isRecording {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

class ShortcutCaptureNSView: NSView {
    var onShortcutCaptured: ((UInt32, UInt32) -> Void)?
    var onCancel: (() -> Void)?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func keyDown(with event: NSEvent) {
        // Escape cancels
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        
        // Require at least Cmd or Ctrl modifier
        let flags = event.modifierFlags
        guard flags.contains(.command) || flags.contains(.control) else {
            return
        }
        
        var carbonModifiers: UInt32 = 0
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        
        onShortcutCaptured?(UInt32(event.keyCode), carbonModifiers)
    }
}

/// Highlightr's bundled syntax themes, read once.
enum ThemeCatalog {
    static let names: [String] = {
        guard let h = Highlightr() else { return [SettingsManager.defaultDarkTheme, SettingsManager.defaultLightTheme] }
        return h.availableThemes().sorted()
    }()
    
    static func displayName(_ name: String) -> String {
        name.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

struct SettingsView: View {
    @ObservedObject var settings = SettingsManager.shared
    
    @State private var editorShortcut: KeyboardShortcut
    @State private var historyShortcut: KeyboardShortcut
    @State private var scratchShortcut: KeyboardShortcut
    @State private var showClearConfirm = false
    @State private var maxHistory: Int
    // Edited locally and applied on Save, so Cancel discards them like it does the shortcuts.
    @State private var pauseHistory: Bool
    @State private var tabSize: Int
    @State private var editorFont: EditorFont
    @State private var useTabs: Bool
    @State private var doubleCopyOpensEditor: Bool
    @State private var darkTheme: String
    @State private var lightTheme: String
    @State private var presentationHighContrast: Bool
    @State private var presentationLineNumbers: Bool
    
    init() {
        let settings = SettingsManager.shared
        _editorShortcut = State(initialValue: settings.editorShortcut)
        _historyShortcut = State(initialValue: settings.historyShortcut)
        _scratchShortcut = State(initialValue: settings.scratchShortcut)
        _maxHistory = State(initialValue: settings.maxHistory)
        _pauseHistory = State(initialValue: settings.pauseHistory)
        _tabSize = State(initialValue: settings.tabSize)
        _editorFont = State(initialValue: settings.editorFont)
        _useTabs = State(initialValue: settings.useTabs)
        _doubleCopyOpensEditor = State(initialValue: settings.doubleCopyOpensEditor)
        _darkTheme = State(initialValue: settings.darkTheme)
        _lightTheme = State(initialValue: settings.lightTheme)
        _presentationHighContrast = State(initialValue: settings.presentationHighContrast)
        _presentationLineNumbers = State(initialValue: settings.presentationLineNumbers)
    }
    
    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 10) {
                Image("MenuBarIcon")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mangle")
                        .font(.title3.weight(.semibold))
                    if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
                        Text("Version \(version)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 20) {
                    section("Keyboard Shortcuts", caption: "Click a shortcut and press a new key combination. Must include ⌘ or ⌃. Press Esc to cancel.") {
                        HStack {
                            Text("Press ⌘C Twice to Edit")
                            Spacer()
                            Toggle("", isOn: $doubleCopyOpensEditor)
                                .labelsHidden()
                        }
                        .help("Copy, then press ⌘C again quickly to open the copied text in the editor. Requires Accessibility access.")
                        Divider()
                        ShortcutRecorder(title: "Open Editor", shortcut: $editorShortcut)
                        ShortcutRecorder(title: "Recent Snippets", shortcut: $historyShortcut)
                        ShortcutRecorder(title: "Scratch Pad", shortcut: $scratchShortcut)
                    }
                    
                    section("General") {
                        HStack {
                            Text("Launch at Login")
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { SMAppService.mainApp.status == .enabled },
                                set: { newValue in
                                    do {
                                        if newValue {
                                            try SMAppService.mainApp.register()
                                        } else {
                                            try SMAppService.mainApp.unregister()
                                        }
                                    } catch {
                                        // login item update failed — silently ignore
                                    }
                                }
                            ))
                            .labelsHidden()
                        }
                        
                        Divider()
                        
                        HStack {
                            Text("Pause History")
                            Spacer()
                            Toggle("", isOn: $pauseHistory)
                                .labelsHidden()
                        }
                        
                        Divider()
                        
                        HStack {
                            Text("History Limit")
                            Spacer()
                            Stepper("\(maxHistory) entries", value: $maxHistory, in: 10...500, step: 10)
                        }
                        
                        Divider()
                        
                        HStack {
                            Text("Clear History")
                            Spacer()
                            Button("Clear") {
                                showClearConfirm = true
                            }
                            .alert("Clear History", isPresented: $showClearConfirm) {
                                Button("Cancel", role: .cancel) {}
                                Button("Clear", role: .destructive) {
                                    NotificationCenter.default.post(name: .clearHistory, object: nil)
                                }
                            } message: {
                                Text("This will permanently delete all clipboard history.")
                            }
                        }
                    }
                }
                
                VStack(spacing: 20) {
                    section("Editor") {
                        HStack {
                            Text("Font")
                            Spacer()
                            Picker("", selection: $editorFont) {
                                ForEach(EditorFont.allCases) { font in
                                    Text(font.rawValue).tag(font)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 160)
                        }
                        
                        Divider()
                        
                        HStack {
                            Text("Dark Theme")
                            Spacer()
                            themePicker($darkTheme)
                        }
                        
                        Divider()
                        
                        HStack {
                            Text("Light Theme")
                            Spacer()
                            themePicker($lightTheme)
                        }
                        
                        Divider()
                        
                        HStack {
                            Text("High Contrast When Presenting")
                            Spacer()
                            Toggle("", isOn: $presentationHighContrast)
                                .labelsHidden()
                        }
                        .help("Presentation mode (⌥⌘P) switches to an accessible high-contrast theme")
                        
                        Divider()
                        
                        HStack {
                            Text("Line Numbers When Presenting")
                            Spacer()
                            Toggle("", isOn: $presentationLineNumbers)
                                .labelsHidden()
                        }
                        .help("Keep line numbers in presentation mode (⌥⌘P), so the audience can refer to them")
                    }
                    
                    section("Default Indentation", caption: "Used for new documents and text whose indentation can't be detected. Change a document's own indentation from the bottom bar.") {
                        HStack {
                            Text("Indent Width")
                            Spacer()
                            Picker("", selection: $tabSize) {
                                Text("2").tag(2)
                                Text("4").tag(4)
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .frame(width: 140)
                        }
                        
                        Divider()
                        
                        HStack {
                            Text("Indent With Tabs")
                            Spacer()
                            Toggle("", isOn: $useTabs)
                                .labelsHidden()
                        }
                    }
                }
            }
            
            HStack {
                Spacer()
                
                Button("Cancel") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.escape, modifiers: [])
                
                Button("Save") {
                    settings.editorShortcut = editorShortcut
                    settings.historyShortcut = historyShortcut
                    settings.scratchShortcut = scratchShortcut
                    settings.maxHistory = maxHistory
                    settings.pauseHistory = pauseHistory
                    settings.tabSize = tabSize
                    settings.editorFont = editorFont
                    settings.useTabs = useTabs
                    settings.doubleCopyOpensEditor = doubleCopyOpensEditor
                    settings.darkTheme = darkTheme
                    settings.lightTheme = lightTheme
                    settings.presentationHighContrast = presentationHighContrast
                    settings.presentationLineNumbers = presentationLineNumbers
                    settings.save()
                    // Apply a lowered limit now rather than on the next copy.
                    AppDelegate.shared?.historyManager.enforceLimit(save: true)
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 720)
        .tint(AppTheme.tealSUI)
    }
    
    /// A titled card of rows, with an optional caption under it.
    private func section<Content: View>(_ title: String, caption: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(spacing: 12) {
                content()
            }
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            if let caption {
                Text(caption)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    
    private func themePicker(_ selection: Binding<String>) -> some View {
        Picker("", selection: selection) {
            ForEach(ThemeCatalog.names, id: \.self) { name in
                Text(ThemeCatalog.displayName(name)).tag(name)
            }
        }
        .labelsHidden()
        .frame(width: 180)
    }
}
