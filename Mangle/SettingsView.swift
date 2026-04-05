import SwiftUI
import Carbon
import Combine
import ServiceManagement

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
    @Published var fontSize: CGFloat {
        didSet {
            UserDefaults.standard.set(Double(fontSize), forKey: fontSizeKey)
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
    
    var onShortcutsChanged: (() -> Void)?
    
    private let editorKey = "EditorShortcut"
    private let historyKey = "HistoryShortcut"
    private let pauseHistoryKey = "PauseHistory"
    private let fontSizeKey = "EditorFontSize"
    private let maxHistoryKey = "MaxHistory"
    private let tabSizeKey = "TabSize"
    
    init() {
        // Default: Ctrl+Cmd+E for editor
        let defaultEditor = KeyboardShortcut(keyCode: 14, modifiers: UInt32(controlKey | cmdKey))
        // Default: Ctrl+Cmd+H for history
        let defaultHistory = KeyboardShortcut(keyCode: 4, modifiers: UInt32(controlKey | cmdKey))
        
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
        
        pauseHistory = UserDefaults.standard.bool(forKey: pauseHistoryKey)
        
        let storedFontSize = UserDefaults.standard.double(forKey: fontSizeKey)
        fontSize = storedFontSize > 0 ? CGFloat(storedFontSize) : NSFont.systemFontSize
        
        let storedMax = UserDefaults.standard.integer(forKey: "MaxHistory")
        maxHistory = storedMax > 0 ? storedMax : 100
        
        let storedTabSize = UserDefaults.standard.integer(forKey: "TabSize")
        tabSize = storedTabSize > 0 ? storedTabSize : 4
    }
    
    func save() {
        if let data = try? JSONEncoder().encode(editorShortcut) {
            UserDefaults.standard.set(data, forKey: editorKey)
        }
        if let data = try? JSONEncoder().encode(historyShortcut) {
            UserDefaults.standard.set(data, forKey: historyKey)
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

struct SettingsView: View {
    @ObservedObject var settings = SettingsManager.shared
    
    @State private var editorShortcut: KeyboardShortcut
    @State private var historyShortcut: KeyboardShortcut
    @State private var showClearConfirm = false
    @State private var maxHistory: Int
    
    init() {
        _editorShortcut = State(initialValue: SettingsManager.shared.editorShortcut)
        _historyShortcut = State(initialValue: SettingsManager.shared.historyShortcut)
        _maxHistory = State(initialValue: SettingsManager.shared.maxHistory)
    }
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Keyboard Shortcuts")
                .font(.headline)
            
            VStack(spacing: 12) {
                ShortcutRecorder(title: "Quick Edit", shortcut: $editorShortcut)
                ShortcutRecorder(title: "Show History", shortcut: $historyShortcut)
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            
            Text("Click a shortcut and press a new key combination.\nMust include ⌘ or ⌃. Press Esc to cancel.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            VStack(spacing: 12) {
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
                    Toggle("", isOn: $settings.pauseHistory)
                        .labelsHidden()
                }
                
                Divider()
                
                HStack {
                    Text("History Limit")
                    Spacer()
                    Stepper("\(maxHistory) entries", value: $maxHistory, in: 10...500, step: 10)
                }
                
                Divider()
                
                Divider()
                
                HStack {
                    Text("Tab Size")
                    Spacer()
                    Picker("", selection: $settings.tabSize) {
                        Text("2 spaces").tag(2)
                        Text("4 spaces").tag(4)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 140)
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
            .padding()
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)
            
            Spacer()
            
            HStack {
                Spacer()
                
                Button("Cancel") {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.escape, modifiers: [])
                
                Button("Save") {
                    settings.editorShortcut = editorShortcut
                    settings.historyShortcut = historyShortcut
                    settings.maxHistory = maxHistory
                    settings.save()
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.bottom, 20)
        }
        .padding()
        .frame(width: 350, height: 540)
        .tint(AppTheme.tealSUI)
    }
}
