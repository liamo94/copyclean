import SwiftUI
import AppKit
import Highlightr

// MARK: - Theme

enum AppTheme {
    static let teal    = NSColor(red: 0.20, green: 0.78, blue: 0.60, alpha: 1.0)
    static let tealSUI = Color(red: 0.20, green: 0.78, blue: 0.60)
    static let editorDarkBG = NSColor(red: 0.11, green: 0.13, blue: 0.13, alpha: 1.0)
    static let gutterDarkBG = NSColor(red: 0.09, green: 0.11, blue: 0.11, alpha: 1.0)
}

// MARK: - Line Number Gutter

class LineNumberRulerView: NSRulerView {
    var fontSize: CGFloat = NSFont.systemFontSize
    var activeLine: Int = 0
    
    override var isFlipped: Bool { true }
    override var requiredThickness: CGFloat { 44 }
    
    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        (isDark ? AppTheme.gutterDarkBG : NSColor(white: 0.95, alpha: 1.0)).setFill()
        bounds.fill()
        
        (isDark ? AppTheme.teal.withAlphaComponent(0.45) : AppTheme.teal.withAlphaComponent(0.25)).setStroke()
        let border = NSBezierPath()
        border.move(to: NSPoint(x: bounds.width - 0.5, y: bounds.minY))
        border.line(to: NSPoint(x: bounds.width - 0.5, y: bounds.maxY))
        border.lineWidth = 1
        border.stroke()
        
        let inactiveAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize * 0.85, weight: .regular),
            .foregroundColor: isDark
            ? AppTheme.teal.withAlphaComponent(0.55)
            : AppTheme.teal.withAlphaComponent(0.65)
        ]
        let activeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize * 0.85, weight: .semibold),
            .foregroundColor: isDark
            ? AppTheme.teal.withAlphaComponent(1.0)
            : AppTheme.teal
        ]
        
        layoutManager.ensureLayout(for: container)
        
        let text  = textView.string as NSString
        let len   = text.length
        let inset = textView.textContainerInset.height
        let width = requiredThickness
        let h     = bounds.height
        // Read scroll position directly from the text view — always current at draw time.
        let scrollOffset = textView.visibleRect.origin.y
        
        func drawNum(_ n: Int, _ docY: CGFloat) {
            // docY is layout-manager space. Add inset → text-view/document space.
            // Subtract scrollOffset → position relative to the ruler's visible top.
            let y = docY + inset - scrollOffset
            guard y > -20 && y < h + 20 else { return }
            let attrs = n == activeLine ? activeAttrs : inactiveAttrs
            let s  = "\(n)" as NSString
            let sz = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: width - sz.width - 10, y: y), withAttributes: attrs)
        }
        
        if len == 0 { drawNum(1, 0); return }
        
        var charIdx = 0
        var lineNum = 1
        while charIdx < len {
            let lineRange = text.lineRange(for: NSRange(location: charIdx, length: 0))
            let glyphIdx  = layoutManager.glyphIndexForCharacter(at: charIdx)
            if glyphIdx < layoutManager.numberOfGlyphs {
                let fragRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIdx, effectiveRange: nil)
                if fragRect != .zero { drawNum(lineNum, fragRect.origin.y) }
            }
            lineNum += 1
            charIdx = NSMaxRange(lineRange)
        }
        
        if len > 0 && text.character(at: len - 1) == ("\n" as NSString).character(at: 0) {
            let extra = layoutManager.extraLineFragmentRect
            if extra != .zero { drawNum(lineNum, extra.origin.y) }
        }
    }
}

// MARK: - Editor View

struct EditorView: View {
    @ObservedObject var viewModel: EditorViewModel
    @ObservedObject private var settings = SettingsManager.shared
    var onSave: () -> Void
    var onClose: () -> Void
    @FocusState private var isTextEditorFocused: Bool
    @State private var keyMonitor: Any?
    @State private var textView: NSTextView?
    @State private var showFindBar = false
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var matchCount = 0
    @FocusState private var isFindFieldFocused: Bool
    @State private var showShortcuts = false
    @State private var hoverTransform = false
    @State private var hoverCancel = false
    @State private var hoverKeyboard = false
    @State private var hoverSave = false
    @State private var hoverWordWrap = false
    
    // Feature 1 – Cursor position
    @State private var cursorLine: Int = 1
    @State private var cursorColumn: Int = 1
    
    // Feature 2 – Regex toggle
    @State private var useRegex = false
    
    // Feature 3 – Unsaved changes warning
    @State private var showCancelAlert = false
    
    
    // Feature 8 – Word wrap toggle
    @State private var wordWrap = true
    
    private static let languages: [(label: String, id: String)] = [
        ("Auto-detect", "auto"),
        ("Plain Text", "plaintext"),
        ("Bash", "bash"),
        ("C", "c"),
        ("C++", "cpp"),
        ("CSS", "css"),
        ("Diff", "diff"),
        ("Go", "go"),
        ("HTML", "xml"),
        ("Java", "java"),
        ("JavaScript", "javascript"),
        ("JSON", "json"),
        ("Kotlin", "kotlin"),
        ("Markdown", "markdown"),
        ("Perl", "perl"),
        ("PHP", "php"),
        ("Python", "python"),
        ("Ruby", "ruby"),
        ("Rust", "rust"),
        ("SQL", "sql"),
        ("Swift", "swift"),
        ("TypeScript", "typescript"),
        ("YAML", "yaml"),
    ]
    
    private var textStats: (lines: Int, words: Int, chars: Int) {
        let t = viewModel.text
        let lines = t.isEmpty ? 1 : t.components(separatedBy: "\n").count
        let words = t.split { $0.isWhitespace || $0.isNewline }.count
        return (lines, words, t.count)
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if showFindBar {
                findBar
                Divider()
            }
            
            CustomTextEditor(
                text: $viewModel.text,
                language: $viewModel.currentLanguage,
                fontSize: settings.fontSize,
                wordWrap: wordWrap,
                onTextViewReady: { tv in
                    textView = tv
                },
                onCursorChange: { line, col in
                    cursorLine = line
                    cursorColumn = col
                }
            )
            .focused($isTextEditorFocused)
            
            Divider()
            
            bottomBar
        }
        .frame(minWidth: 400, minHeight: 320)
        .background {
            Button("") {
                showFindBar.toggle()
                if showFindBar { isFindFieldFocused = true }
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTextEditorFocused = true
            }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                
                // When discard alert is open, intercept its shortcuts first
                if showCancelAlert {
                    if event.keyCode == 53 { // Escape
                        showCancelAlert = false
                        return nil
                    }
                    if mods == .command && event.charactersIgnoringModifiers == "d" {
                        showCancelAlert = false
                        closeFindBar()
                        onClose()
                        return nil
                    }
                    return nil // swallow all other keys while alert is open
                }
                
                if mods == .command {
                    switch event.charactersIgnoringModifiers {
                    case "=", "+":
                        settings.fontSize = min(settings.fontSize + 1, 36)
                        return nil
                    case "-":
                        settings.fontSize = max(settings.fontSize - 1, 9)
                        return nil
                    case "0":
                        settings.fontSize = NSFont.systemFontSize
                        return nil
                    case "d":
                        if let tv = textView { duplicateLine(in: tv) }
                        return nil
                    case "l":
                        if let tv = textView { selectLine(in: tv) }
                        return nil
                    default: break
                    }
                }
                
                if mods == [.command, .shift],
                   event.charactersIgnoringModifiers?.lowercased() == "k" {
                    if let tv = textView { deleteLine(in: tv) }
                    return nil
                }
                
                let optionOnly = mods.contains(.option)
                && !mods.contains(.command)
                && !mods.contains(.shift)
                && !mods.contains(.control)
                if optionOnly {
                    if event.keyCode == 126 {
                        if let tv = textView { moveLine(in: tv, up: true) }
                        return nil
                    }
                    if event.keyCode == 125 {
                        if let tv = textView { moveLine(in: tv, up: false) }
                        return nil
                    }
                }
                
                return event
            }
        }
        .onDisappear {
            if let monitor = keyMonitor {
                NSEvent.removeMonitor(monitor)
                keyMonitor = nil
            }
        }
        .overlay {
            if showCancelAlert {
                ZStack {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                    
                    VStack(spacing: 0) {
                        Divider()
                        HStack(spacing: 0) {
                            Text("Discard unsaved changes?")
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 14)
                            
                            Spacer()
                            
                            barDivider
                            
                            // Keep Editing
                            Button { showCancelAlert = false } label: {
                                bottomAction("Keep Editing", shortcut: "Esc")
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut(.escape, modifiers: [])
                            .padding(.horizontal, 8)
                            
                            barDivider
                            
                            // Discard
                            Button {
                                showCancelAlert = false
                                closeFindBar()
                                onClose()
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text("Discard")
                                        .fontWeight(.medium)
                                        .foregroundColor(.red.opacity(0.85))
                                    Text("⌘D")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundColor(.secondary)
                                }
                                .font(.system(size: 12))
                                .fixedSize()
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .cornerRadius(5)
                            }
                            .buttonStyle(.plain)
                            .keyboardShortcut("d", modifiers: .command)
                            .padding(.horizontal, 8)
                        }
                        .frame(height: 36)
                        .background(Color(nsColor: .windowBackgroundColor))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
        }
    }
    
    // MARK: - Find Bar
    
    private var findBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(AppTheme.tealSUI)
                    .frame(width: 16)
                TextField("Find", text: $findText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFindFieldFocused)
                    .onChange(of: findText) { highlightMatches() }
                    .onSubmit { findNext() }
                // Feature 2 – regex toggle button
                Button {
                    useRegex.toggle()
                    highlightMatches()
                } label: {
                    Text(".*")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(useRegex ? .white : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(useRegex ? AppTheme.tealSUI : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.borderless)
                .help("Use Regular Expression")
                
                if isInvalidRegex {
                    Text("Invalid")
                        .font(.caption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.red.opacity(0.7), in: Capsule())
                } else if matchCount > 0 {
                    Text("\(matchCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(AppTheme.tealSUI, in: Capsule())
                } else if !findText.isEmpty {
                    Text("0")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.5), in: Capsule())
                }
                Button(action: findPrevious) { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless)
                Button(action: findNext) { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless)
                Button(action: closeFindBar) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 8) {
                Image(systemName: "arrow.2.squarepath")
                    .foregroundColor(.secondary)
                    .frame(width: 16)
                TextField("Replace", text: $replaceText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { replaceCurrent() }
                Button("Replace") { replaceCurrent() }
                    .tint(AppTheme.tealSUI)
                Button("All") { replaceAll() }
                    .tint(AppTheme.tealSUI)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    // MARK: - Language Picker
    
    private var currentLanguageLabel: String {
        Self.languages.first { $0.id == viewModel.currentLanguage }?.label ?? viewModel.currentLanguage
    }
    
    @ViewBuilder private var languagePickerItems: some View {
        ForEach(Self.languages, id: \.id) { lang in
            Button {
                if lang.id == "auto" {
                    viewModel.currentLanguage = CustomTextEditor.Coordinator.guessLanguage(viewModel.text)
                    viewModel.languageIsManual = false
                } else {
                    viewModel.currentLanguage = lang.id
                    viewModel.languageIsManual = true
                }
            } label: {
                HStack {
                    Text(lang.label)
                    if viewModel.currentLanguage == lang.id {
                        Spacer()
                        Image(systemName: "checkmark")
                    }
                }
            }
        }
    }
    
    // MARK: - Bottom Bar
    
    private var bottomBar: some View {
        ViewThatFits(in: .horizontal) {
            bottomBarHStack(showStats: true,  showKeyboard: true)
            bottomBarHStack(showStats: false, showKeyboard: true)
            bottomBarHStack(showStats: false, showKeyboard: false)
        }
        .frame(height: 36)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    @ViewBuilder
    private func bottomBarHStack(showStats: Bool, showKeyboard: Bool) -> some View {
        HStack(spacing: 0) {
            // Cursor position
            Text("\(cursorLine):\(cursorColumn)")
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(AppTheme.tealSUI)
                .fixedSize()
                .padding(.horizontal, 10)
            
            barDivider
            
            if showStats {
                HStack(spacing: 10) {
                    statPill(value: "\(textStats.lines)", label: "ln", valueWidth: 18)
                    statPill(value: "\(textStats.words)", label: "wd", valueWidth: 24)
                    statPill(value: "\(textStats.chars)", label: "ch", valueWidth: 34)
                }
                .fixedSize()
                .padding(.horizontal, 10)
                barDivider
            }
            
            // Transform menu
            Menu {
                Menu("Language: \(currentLanguageLabel)") {
                    languagePickerItems
                }
                
                Divider()
                
                if viewModel.currentLanguage == "json" || PrettierFormatter.shared.canFormat(language: viewModel.currentLanguage) {
                    Button("Format Code") { formatCode() }
                        .keyboardShortcut("f", modifiers: [.command, .shift])
                    Divider()
                }
                
                Section("Whitespace") {
                    Button("Trim Whitespace") {
                        transform { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    
                    Button("Normalize Indentation") {
                        transform { text in
                            let tabWidth = SettingsManager.shared.tabSize
                            let lines = text.components(separatedBy: "\n")
                            let expandedLines = lines.map { line -> String in
                                line.replacingOccurrences(of: "\t", with: String(repeating: " ", count: tabWidth))
                            }
                            let minIndent = expandedLines
                                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                                .map { $0.prefix(while: { $0 == " " }).count }
                                .min() ?? 0
                            return expandedLines.map { line in
                                line.count >= minIndent ? String(line.dropFirst(minIndent)) : line
                            }.joined(separator: "\n")
                        }
                    }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    
                    Button("Remove All Indentation") {
                        transform {
                            $0.components(separatedBy: "\n")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .joined(separator: "\n")
                        }
                    }
                    Button("Remove Blank Lines") {
                        transform {
                            $0.components(separatedBy: "\n")
                                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                                .joined(separator: "\n")
                        }
                    }
                    Button("Tabs → Spaces") {
                        transform {
                            let spaces = String(repeating: " ", count: SettingsManager.shared.tabSize)
                            return $0.replacingOccurrences(of: "\t", with: spaces)
                        }
                    }
                    Button("Spaces → Tabs") {
                        transform {
                            let tabSize = SettingsManager.shared.tabSize
                            return $0.components(separatedBy: "\n").map { line in
                                var leadingSpaces = 0
                                for ch in line { if ch == " " { leadingSpaces += 1 } else { break } }
                                let tabs = leadingSpaces / tabSize
                                let remainder = leadingSpaces % tabSize
                                return String(repeating: "\t", count: tabs)
                                + String(repeating: " ", count: remainder)
                                + line.dropFirst(leadingSpaces)
                            }.joined(separator: "\n")
                        }
                    }
                }
                
                Section("Case") {
                    Button("lowercase") { transform { $0.lowercased() } }
                        .keyboardShortcut("l", modifiers: [.command, .shift])
                    Button("UPPERCASE") { transform { $0.uppercased() } }
                        .keyboardShortcut("u", modifiers: [.command, .shift])
                    Button("Title Case") {
                        transform {
                            let small: Set<String> = ["a","an","the","and","but","or","for","nor","so","yet","at","by","in","of","on","to","up","as"]
                            return $0.components(separatedBy: "\n").map { line in
                                let words = line.components(separatedBy: " ")
                                return words.enumerated().map { i, word in
                                    let lower = word.lowercased()
                                    if i > 0 && small.contains(lower) { return lower }
                                    return word.prefix(1).uppercased() + word.dropFirst().lowercased()
                                }.joined(separator: " ")
                            }.joined(separator: "\n")
                        }
                    }
                }
                
                Section("Lines") {
                    Button("Sort Lines") {
                        transform {
                            $0.components(separatedBy: "\n").sorted().joined(separator: "\n")
                        }
                    }
                    Button("Remove Duplicate Lines") {
                        transform {
                            var seen = Set<String>()
                            return $0.components(separatedBy: "\n")
                                .filter { seen.insert($0).inserted }
                                .joined(separator: "\n")
                        }
                    }
                    Button("Reverse Lines") {
                        transform {
                            $0.components(separatedBy: "\n").reversed().joined(separator: "\n")
                        }
                    }
                }
                
                // Feature 9 – Line endings in Transform menu
                Section("Line Endings") {
                    Button("Convert to LF") {
                        transform {
                            $0.replacingOccurrences(of: "\r\n", with: "\n")
                                .replacingOccurrences(of: "\r",   with: "\n")
                        }
                    }
                    Button("Convert to CRLF") {
                        transform {
                            let lf = $0.replacingOccurrences(of: "\r\n", with: "\n")
                                .replacingOccurrences(of: "\r",   with: "\n")
                            return lf.replacingOccurrences(of: "\n", with: "\r\n")
                        }
                    }
                    Button("Convert to CR") {
                        transform {
                            let lf = $0.replacingOccurrences(of: "\r\n", with: "\n")
                                .replacingOccurrences(of: "\r",   with: "\n")
                            return lf.replacingOccurrences(of: "\n", with: "\r")
                        }
                    }
                }
            } label: {
                bottomAction("Transform", shortcut: "⌘T", hovered: hoverTransform)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(.horizontal, 8)
            .onHover { hoverTransform = $0 }
            
            barDivider
            
            Spacer(minLength: 0)
            
            // Feature 8 – Word wrap toggle
            Button {
                wordWrap.toggle()
            } label: {
                Image(systemName: "arrow.down.and.line.horizontal.and.arrow.up")
                    .foregroundColor(wordWrap ? AppTheme.tealSUI : .secondary)
                    .font(.system(size: 12))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(hoverWordWrap ? Color.secondary.opacity(0.12) : Color.clear)
                    .cornerRadius(5)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .onHover { hoverWordWrap = $0 }
            .overlay(alignment: .top) {
                if hoverWordWrap {
                    Text(wordWrap ? "Word Wrap: On" : "Word Wrap: Off")
                        .font(.caption)
                        .foregroundColor(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                        .fixedSize()
                        .offset(y: -30)
                        .allowsHitTesting(false)
                }
            }
            
            barDivider
            
            // Feature 3 – Cancel with unsaved-changes guard
            Button {
                closeFindBar()
                if viewModel.isDirty {
                    showCancelAlert = true
                } else {
                    onClose()
                }
            } label: {
                bottomAction("Cancel", shortcut: "Esc", hovered: hoverCancel)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            .padding(.horizontal, 8)
            .onHover { hoverCancel = $0 }
            
            barDivider
            
            // Save
            Button {
                onSave()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Save")
                        .fontWeight(.medium)
                        .foregroundColor(hoverSave ? AppTheme.tealSUI : AppTheme.tealSUI.opacity(0.8))
                    shortcutBadge("⌘S", hovered: hoverSave)
                }
                .font(.system(size: 12))
                .fixedSize()
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(hoverSave ? Color.secondary.opacity(0.12) : Color.clear)
                .cornerRadius(5)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: .command)
            .padding(.horizontal, 8)
            .onHover { hoverSave = $0 }
            
            if showKeyboard {
                barDivider
                
                Button {
                    showShortcuts.toggle()
                } label: {
                    Image(systemName: "keyboard")
                        .foregroundColor(showShortcuts || hoverKeyboard ? AppTheme.tealSUI : .secondary)
                        .font(.system(size: 12))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(hoverKeyboard ? Color.secondary.opacity(0.12) : Color.clear)
                        .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showShortcuts, arrowEdge: .top) {
                    ShortcutsPopover()
                }
                .padding(.horizontal, 8)
                .onHover { hoverKeyboard = $0 }
            }
        }
    }
    
    private var barDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.2))
            .frame(width: 1, height: 16)
    }
    
    @ViewBuilder
    private func bottomAction(_ label: String, shortcut: String, hovered: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .foregroundColor(hovered ? .primary : .primary.opacity(0.75))
            shortcutBadge(shortcut, hovered: hovered)
        }
        .font(.system(size: 12))
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(hovered ? Color.secondary.opacity(0.12) : Color.clear)
        .cornerRadius(5)
    }
    
    @ViewBuilder
    private func shortcutBadge(_ text: String, hovered: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .foregroundColor(hovered ? .secondary : .secondary.opacity(0.6))
    }
    
    @ViewBuilder
    private func statPill(value: String, label: String, valueWidth: CGFloat) -> some View {
        HStack(spacing: 3) {
            Text(value)
                .monospacedDigit()
                .foregroundColor(AppTheme.tealSUI)
                .frame(width: valueWidth, alignment: .trailing)
            Text(label)
                .foregroundColor(.secondary)
        }
        .font(.caption)
    }
    
    // MARK: - Find Logic
    
    /// Build an NSRegularExpression from the current findText, returning nil when invalid.
    private func buildRegex() -> NSRegularExpression? {
        guard useRegex, !findText.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: findText, options: .caseInsensitive)
    }
    
    private var isInvalidRegex: Bool {
        guard useRegex, !findText.isEmpty else { return false }
        return (try? NSRegularExpression(pattern: findText)) == nil
    }
    
    private func highlightMatches() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.backgroundColor, range: fullRange)
        
        guard !findText.isEmpty else { matchCount = 0; return }
        
        let nsText = tv.string as NSString
        var count = 0
        
        if useRegex {
            guard let regex = buildRegex() else { matchCount = 0; return }
            let matches = regex.matches(in: tv.string, range: NSRange(location: 0, length: nsText.length))
            for m in matches {
                storage.addAttribute(.backgroundColor, value: AppTheme.teal.withAlphaComponent(0.28), range: m.range)
            }
            count = matches.count
        } else {
            var searchRange = NSRange(location: 0, length: nsText.length)
            while searchRange.location < nsText.length {
                let range = nsText.range(of: findText, options: .caseInsensitive, range: searchRange)
                if range.location == NSNotFound { break }
                storage.addAttribute(.backgroundColor, value: AppTheme.teal.withAlphaComponent(0.28), range: range)
                count += 1
                searchRange.location = range.location + range.length
                searchRange.length = nsText.length - searchRange.location
            }
        }
        matchCount = count
    }
    
    private func findNext() {
        guard let tv = textView, !findText.isEmpty else { return }
        let nsText = tv.string as NSString
        let currentPos = tv.selectedRange().location + tv.selectedRange().length
        
        if useRegex {
            guard let regex = buildRegex() else { return }
            let fullLength = nsText.length
            // Search from cursor to end, then wrap
            for searchStart in [currentPos, 0] {
                let searchRange = NSRange(location: searchStart, length: fullLength - searchStart)
                if let m = regex.firstMatch(in: tv.string, range: searchRange) {
                    tv.setSelectedRange(m.range)
                    tv.scrollRangeToVisible(m.range)
                    return
                }
            }
        } else {
            let text = nsText
            var searchRange = NSRange(location: currentPos, length: text.length - currentPos)
            var range = text.range(of: findText, options: .caseInsensitive, range: searchRange)
            if range.location == NSNotFound {
                searchRange = NSRange(location: 0, length: text.length)
                range = text.range(of: findText, options: .caseInsensitive, range: searchRange)
            }
            if range.location != NSNotFound {
                tv.setSelectedRange(range)
                tv.scrollRangeToVisible(range)
            }
        }
    }
    
    private func findPrevious() {
        guard let tv = textView, !findText.isEmpty else { return }
        let nsText = tv.string as NSString
        let currentPos = tv.selectedRange().location
        
        if useRegex {
            guard let regex = buildRegex() else { return }
            let fullLength = nsText.length
            // Collect all matches then find the last one before cursor
            let allMatches = regex.matches(in: tv.string, range: NSRange(location: 0, length: fullLength))
            let before = allMatches.filter { $0.range.location < currentPos }
            let target = before.last ?? allMatches.last
            if let m = target {
                tv.setSelectedRange(m.range)
                tv.scrollRangeToVisible(m.range)
            }
        } else {
            let text = nsText
            var searchRange = NSRange(location: 0, length: currentPos)
            var range = text.range(of: findText, options: [.caseInsensitive, .backwards], range: searchRange)
            if range.location == NSNotFound {
                searchRange = NSRange(location: 0, length: text.length)
                range = text.range(of: findText, options: [.caseInsensitive, .backwards], range: searchRange)
            }
            if range.location != NSNotFound {
                tv.setSelectedRange(range)
                tv.scrollRangeToVisible(range)
            }
        }
    }
    
    private func replaceCurrent() {
        guard let tv = textView, !findText.isEmpty else { return }
        let selectedRange = tv.selectedRange()
        let selectedText = (tv.string as NSString).substring(with: selectedRange)
        
        if useRegex {
            guard let regex = buildRegex() else { return }
            let fullSelected = NSRange(location: 0, length: (selectedText as NSString).length)
            if regex.firstMatch(in: selectedText, range: fullSelected) != nil {
                let replaced = regex.stringByReplacingMatches(in: selectedText, range: fullSelected, withTemplate: replaceText)
                tv.insertText(replaced, replacementRange: selectedRange)
                highlightMatches()
            }
        } else {
            if selectedText.caseInsensitiveCompare(findText) == .orderedSame {
                tv.insertText(replaceText, replacementRange: selectedRange)
                highlightMatches()
            }
        }
        findNext()
    }
    
    private func replaceAll() {
        guard !findText.isEmpty else { return }
        if useRegex {
            guard let regex = buildRegex() else { return }
            transform { text in
                regex.stringByReplacingMatches(
                    in: text,
                    range: NSRange(location: 0, length: (text as NSString).length),
                    withTemplate: replaceText
                )
            }
        } else {
            transform { text in
                text.replacingOccurrences(of: findText, with: replaceText, options: .caseInsensitive)
            }
        }
        highlightMatches()
    }
    
    // MARK: - Line Operations
    
    private func lineExtents(in tv: NSTextView) -> (lineStart: Int, lineEnd: Int, contentsEnd: Int, colOffset: Int) {
        let text = tv.string as NSString
        let sel = tv.selectedRange()
        var ls = 0, le = 0, ce = 0
        text.getLineStart(&ls, end: &le, contentsEnd: &ce, for: sel)
        return (ls, le, ce, sel.location - ls)
    }
    
    private func duplicateLine(in tv: NSTextView) {
        let text = tv.string as NSString
        let (ls, le, ce, col) = lineExtents(in: tv)
        let lineText = text.substring(with: NSRange(location: ls, length: ce - ls))
        let insertion = lineText + "\n"
        let insertRange = NSRange(location: le, length: 0)
        if tv.shouldChangeText(in: insertRange, replacementString: insertion) {
            tv.replaceCharacters(in: insertRange, with: insertion)
            tv.didChangeText()
            let newPos = min(le + col, (tv.string as NSString).length)
            tv.setSelectedRange(NSRange(location: newPos, length: 0))
        }
    }
    
    private func deleteLine(in tv: NSTextView) {
        let (ls, le, _, _) = lineExtents(in: tv)
        let deleteRange = NSRange(location: ls, length: le - ls)
        if tv.shouldChangeText(in: deleteRange, replacementString: "") {
            tv.replaceCharacters(in: deleteRange, with: "")
            tv.didChangeText()
            tv.setSelectedRange(NSRange(location: min(ls, (tv.string as NSString).length), length: 0))
        }
    }
    
    private func selectLine(in tv: NSTextView) {
        let (ls, _, ce, _) = lineExtents(in: tv)
        tv.setSelectedRange(NSRange(location: ls, length: ce - ls))
    }
    
    private func moveLine(in tv: NSTextView, up: Bool) {
        let text = tv.string as NSString
        let (ls, le, ce, col) = lineExtents(in: tv)
        let currentLine = text.substring(with: NSRange(location: ls, length: ce - ls))
        let currentHasNewline = le > ce
        
        if up {
            guard ls > 0 else { return }
            var pls = 0, ple = 0, pce = 0
            text.getLineStart(&pls, end: &ple, contentsEnd: &pce, for: NSRange(location: ls - 1, length: 0))
            let prevLine = text.substring(with: NSRange(location: pls, length: pce - pls))
            let replacement = currentLine + "\n" + prevLine + (currentHasNewline ? "\n" : "")
            let swapRange = NSRange(location: pls, length: le - pls)
            if tv.shouldChangeText(in: swapRange, replacementString: replacement) {
                tv.replaceCharacters(in: swapRange, with: replacement)
                tv.didChangeText()
                tv.setSelectedRange(NSRange(location: min(pls + col, (tv.string as NSString).length), length: 0))
            }
        } else {
            guard le < text.length else { return }
            var nls = 0, nle = 0, nce = 0
            text.getLineStart(&nls, end: &nle, contentsEnd: &nce, for: NSRange(location: le, length: 0))
            let nextLine = text.substring(with: NSRange(location: nls, length: nce - nls))
            let nextHasNewline = nle > nce
            let replacement = nextLine + "\n" + currentLine + (nextHasNewline ? "\n" : "")
            let swapRange = NSRange(location: ls, length: nle - ls)
            if tv.shouldChangeText(in: swapRange, replacementString: replacement) {
                tv.replaceCharacters(in: swapRange, with: replacement)
                tv.didChangeText()
                let newLineStart = ls + (nextLine as NSString).length + 1
                tv.setSelectedRange(NSRange(location: min(newLineStart + col, (tv.string as NSString).length), length: 0))
            }
        }
    }
    
    private func closeFindBar() {
        showFindBar = false
        findText = ""
        replaceText = ""
        matchCount = 0
        if let tv = textView, let storage = tv.textStorage {
            storage.removeAttribute(.backgroundColor, range: NSRange(location: 0, length: storage.length))
        }
    }
    
    // MARK: - Format Code
    
    private func formatCode() {
        let lang = viewModel.currentLanguage
        
        // JSON: use native formatter (fast, no JS overhead)
        if lang == "json" {
            let text = viewModel.text
            guard let data = text.data(using: .utf8),
                  let obj  = try? JSONSerialization.jsonObject(with: data),
                  let out  = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .withoutEscapingSlashes]),
                  let formatted = String(data: out, encoding: .utf8), !formatted.isEmpty else {
                AppDelegate.shared?.showToast("Format failed — check syntax")
                return
            }
            transform { _ in formatted }
            AppDelegate.shared?.showToast("Formatted")
            return
        }
        
        // Everything else: Prettier via JavaScriptCore
        let code    = viewModel.text
        let tabSize = SettingsManager.shared.tabSize
        
        Task {
            do {
                let formatted = try await PrettierFormatter.shared.format(
                    code: code, language: lang, tabSize: tabSize)
                await MainActor.run {
                    transform { _ in formatted }
                    AppDelegate.shared?.showToast("Formatted")
                }
            } catch PrettierError.syntaxError {
                await MainActor.run {
                    AppDelegate.shared?.showToast("Format failed — check syntax")
                }
            } catch {
                await MainActor.run {
                    AppDelegate.shared?.showToast("Format failed")
                }
            }
        }
    }
    
    private func transform(_ operation: (String) -> String) {
        guard let textView = textView else {
            viewModel.text = operation(viewModel.text)
            return
        }
        let oldText = textView.string
        let newText = operation(oldText)
        let savedRange = textView.selectedRange()
        // Clamp saved range to new text length in case text got shorter
        let clampedLocation = min(savedRange.location, (newText as NSString).length)
        let clampedLength = min(savedRange.length, (newText as NSString).length - clampedLocation)
        let restoredRange = NSRange(location: clampedLocation, length: clampedLength)
        
        guard let undoManager = textView.undoManager else {
            textView.allowsUndo = false
            textView.string = newText
            viewModel.text = newText
            textView.allowsUndo = true
            textView.setSelectedRange(restoredRange)
            return
        }
        let vm = viewModel
        func apply(tv: NSTextView, to text: String, undoing revert: String, restoring range: NSRange) {
            tv.allowsUndo = false
            tv.string = text
            vm.text = text
            tv.setSelectedRange(range)
            tv.allowsUndo = true
            undoManager.registerUndo(withTarget: tv) { innerTv in
                apply(tv: innerTv, to: revert, undoing: text, restoring: savedRange)
            }
        }
        apply(tv: textView, to: newText, undoing: oldText, restoring: restoredRange)
    }
}

/// MARK: - NSTextView subclass with VS Code word movement

final class MangleTextView: NSTextView {
    
    // MARK: Key interception (most reliable — fires before interpretKeyEvents)
    
    override func keyDown(with event: NSEvent) {
        let opt   = event.modifierFlags.contains(.option)
        let shift = event.modifierFlags.contains(.shift)
        let cmd   = event.modifierFlags.contains(.command)
        let ctrl  = event.modifierFlags.contains(.control)
        
        // Only handle plain Option+Arrow / Option+Shift+Arrow / Option+Delete
        if opt && !cmd && !ctrl {
            switch event.keyCode {
            case 124: // Right arrow
                shift ? moveWordForwardAndModifySelection(nil) : moveWordForward(nil)
                return
            case 123: // Left arrow
                shift ? moveWordBackwardAndModifySelection(nil) : moveWordBackward(nil)
                return
            case 51: // Delete (backspace)
                if !shift { deleteWordBackward(nil); return }
            default:
                break
            }
        }
        super.keyDown(with: event)
    }
    
    // MARK: Overrides
    
    override func moveWordForward(_ sender: Any?) {
        let sel = selectedRange()
        setSelectedRange(NSRange(location: vscodeWordEnd(from: sel.location + sel.length), length: 0))
    }
    
    override func moveWordBackward(_ sender: Any?) {
        let sel = selectedRange()
        setSelectedRange(NSRange(location: vscodeWordStart(from: sel.location), length: 0))
    }
    
    override func moveWordForwardAndModifySelection(_ sender: Any?) {
        let sel = selectedRange()
        let dest = vscodeWordEnd(from: sel.location + sel.length)
        setSelectedRange(NSRange(location: sel.location, length: dest - sel.location))
    }
    
    override func moveWordBackwardAndModifySelection(_ sender: Any?) {
        let sel = selectedRange()
        let dest = vscodeWordStart(from: sel.location)
        setSelectedRange(NSRange(location: dest, length: (sel.location + sel.length) - dest))
    }
    
    override func deleteWordBackward(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length == 0 else { super.deleteWordBackward(sender); return }
        let dest = vscodeWordStart(from: sel.location)
        let range = NSRange(location: dest, length: sel.location - dest)
        guard range.length > 0, shouldChangeText(in: range, replacementString: "") else { return }
        replaceCharacters(in: range, with: "")
        didChangeText()
    }
    
    // MARK: VS Code word algorithm (NSString / unichar based)
    
    private func wcIsWord(_ c: unichar) -> Bool {
        (c >= 65 && c <= 90)  ||  // A-Z
        (c >= 97 && c <= 122) ||  // a-z
        (c >= 48 && c <= 57)  ||  // 0-9
        c == 95                    // _
    }
    
    private func wcIsSpace(_ c: unichar) -> Bool {
        c == 32 || c == 9 || c == 10 || c == 13
    }
    
    private func vscodeWordEnd(from pos: Int) -> Int {
        let s = string as NSString
        let n = s.length
        var i = pos
        while i < n && wcIsSpace(s.character(at: i)) { i += 1 }
        guard i < n else { return n }
        if wcIsWord(s.character(at: i)) {
            while i < n && wcIsWord(s.character(at: i)) { i += 1 }
        } else {
            while i < n && !wcIsWord(s.character(at: i)) && !wcIsSpace(s.character(at: i)) { i += 1 }
        }
        return i
    }
    
    private func vscodeWordStart(from pos: Int) -> Int {
        let s = string as NSString
        var i = pos
        while i > 0 && wcIsSpace(s.character(at: i - 1)) { i -= 1 }
        guard i > 0 else { return 0 }
        if wcIsWord(s.character(at: i - 1)) {
            while i > 0 && wcIsWord(s.character(at: i - 1)) { i -= 1 }
        } else {
            while i > 0 && !wcIsWord(s.character(at: i - 1)) && !wcIsSpace(s.character(at: i - 1)) { i -= 1 }
        }
        return i
    }
}

// MARK: - Custom Text Editor

struct CustomTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var language: String
    var fontSize: CGFloat
    var wordWrap: Bool
    var onTextViewReady: ((NSTextView) -> Void)?
    var onCursorChange: ((Int, Int) -> Void)?
    
    func makeNSView(context: Context) -> NSView {
        guard let highlightr = Highlightr() else {
            // Fallback: return a plain NSScrollView with a basic NSTextView
            let tv = NSTextView()
            tv.isEditable = true
            tv.allowsUndo = true
            let sv = NSScrollView()
            sv.documentView = tv
            sv.hasVerticalScroller = true
            return sv
        }
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        highlightr.setTheme(to: isDark ? "atom-one-dark" : "xcode")
        highlightr.theme.setCodeFont(.monospacedSystemFont(ofSize: fontSize, weight: .regular))
        
        let textStorage = CodeAttributedString(highlightr: highlightr)
        textStorage.language = "plaintext"
        
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        
        let textView = MangleTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = context.coordinator
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isRichText = true
        
        if isDark {
            textView.backgroundColor = highlightr.theme.themeBackgroundColor ?? AppTheme.editorDarkBG
        }
        textView.insertionPointColor = isDark ? AppTheme.teal : NSColor(AppTheme.tealSUI)
        
        textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        // Layer-backed so AppKit clips the ruler to the scroll view's own bounds,
        // preventing it from rendering over the SwiftUI bottom bar.
        scrollView.wantsLayer = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        
        let rulerView = LineNumberRulerView(scrollView: scrollView, orientation: .verticalRuler)
        rulerView.clientView = textView
        rulerView.fontSize = fontSize
        scrollView.verticalRulerView = rulerView
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        
        context.coordinator.rulerView = rulerView
        context.coordinator.scrollView = scrollView
        context.coordinator.highlightr = highlightr
        context.coordinator.codeStorage = textStorage
        
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.gutterNeedsRedraw),
            name: NSTextStorage.didProcessEditingNotification, object: textView.textStorage
        )
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.gutterNeedsRedraw),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        
        let coordinator = context.coordinator
        DispatchQueue.main.async {
            onTextViewReady?(textView)
            coordinator.detectAndApplyLanguage(for: text)
        }
        return scrollView
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.isApplyingProgrammaticChange = true
        defer { context.coordinator.isApplyingProgrammaticChange = false }
        
        guard let scrollView = nsView as? NSScrollView,
              let textView = scrollView.documentView as? NSTextView else { return }
        
        if textView.string != text {
            let storage = textView.textStorage
            storage?.replaceCharacters(in: NSRange(location: 0, length: storage?.length ?? 0), with: text)
            context.coordinator.detectAndApplyLanguage(for: text)
        }
        
        // Apply manual language change from the picker
        if let storage = context.coordinator.codeStorage, storage.language != language {
            storage.language = language
        }
        
        let newFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let fontChanged = context.coordinator.rulerView?.fontSize != fontSize
        if fontChanged {
            context.coordinator.rulerView?.fontSize = fontSize
        }
        
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let theme = isDark ? "atom-one-dark" : "xcode"
        let themeChanged = context.coordinator.lastAppliedTheme != theme
        if themeChanged {
            context.coordinator.lastAppliedTheme = theme
            context.coordinator.highlightr?.setTheme(to: theme)
        }
        if themeChanged || fontChanged {
            context.coordinator.highlightr?.theme.setCodeFont(newFont)
            // Re-highlight the entire text so the new font applies immediately,
            // not just on the next edit.
            if let storage = context.coordinator.codeStorage {
                let lang = storage.language
                storage.language = ""
                storage.language = lang
            }
            textView.typingAttributes[.font] = newFont
            context.coordinator.rulerView?.needsDisplay = true
        }
        if isDark {
            textView.backgroundColor = context.coordinator.highlightr?.theme.themeBackgroundColor ?? AppTheme.editorDarkBG
            textView.insertionPointColor = AppTheme.teal
        } else {
            textView.backgroundColor = context.coordinator.highlightr?.theme.themeBackgroundColor ?? .textBackgroundColor
            textView.insertionPointColor = NSColor(AppTheme.tealSUI)
        }
        
        // Feature 8 – Word wrap
        if wordWrap != context.coordinator.currentWordWrap {
            context.coordinator.currentWordWrap = wordWrap
            let rulerView = context.coordinator.rulerView
            if wordWrap {
                textView.isHorizontallyResizable = false
                textView.autoresizingMask = [.width]
                scrollView.hasHorizontalScroller = false
                // tile() updates the clip view dimensions but does NOT resize documentView.
                // We must explicitly shrink the textView (which may have grown wide in OFF mode).
                scrollView.tile()
                // contentView.frame.width is the full scrollView width; ruler sits inside it.
                let rulerWidth = scrollView.verticalRulerView?.frame.width ?? 0
                let targetWidth = scrollView.contentView.frame.width - rulerWidth
                var newFrame = textView.frame
                newFrame.size.width = targetWidth
                textView.frame = newFrame
                // Seed the container width; widthTracksTextView keeps it in sync on future resizes.
                let inset = textView.textContainerInset
                textView.textContainer?.containerSize = NSSize(
                    width: max(targetWidth - inset.width * 2, 0),
                    height: .greatestFiniteMagnitude
                )
                textView.textContainer?.widthTracksTextView = true
            } else {
                textView.isHorizontallyResizable = true
                textView.autoresizingMask = []
                textView.textContainer?.widthTracksTextView = false
                textView.textContainer?.containerSize = NSSize(
                    width: CGFloat.greatestFiniteMagnitude,
                    height: CGFloat.greatestFiniteMagnitude
                )
                scrollView.hasHorizontalScroller = true
            }
            textView.layoutManager?.invalidateLayout(
                forCharacterRange: NSRange(location: 0, length: textView.string.utf16.count),
                actualCharacterRange: nil
            )
            rulerView?.needsDisplay = true
        }
    }
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CustomTextEditor
        var rulerView: LineNumberRulerView?
        var scrollView: NSScrollView?
        var highlightr: Highlightr?
        var codeStorage: CodeAttributedString?
        var lastAppliedTheme: String?
        // Feature 8
        var currentWordWrap: Bool = true
        // Bracket highlighting
        var bracketHighlightRanges: [NSRange] = []
        // Suppresses cursor callbacks during programmatic text replacement from updateNSView
        var isApplyingProgrammaticChange = false
        
        init(_ parent: CustomTextEditor) { self.parent = parent }
        
        deinit {
            NotificationCenter.default.removeObserver(self)
        }
        
        func detectAndApplyLanguage(for text: String) {
            guard let codeStorage, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                let detected = Self.guessLanguage(text)
                DispatchQueue.main.async {
                    codeStorage.language = detected
                    self.parent.language = detected
                }
            }
        }
        
        static func guessLanguage(_ text: String) -> String {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return "plaintext" }
            let lines = t.components(separatedBy: "\n")
            let firstLine = lines.first ?? ""
            
            // Shebang — unambiguous interpreter hint
            if firstLine.hasPrefix("#!") {
                if firstLine.contains("python")                          { return "python" }
                if firstLine.contains("ruby")                            { return "ruby" }
                if firstLine.contains("node") || firstLine.contains("deno") { return "javascript" }
                return "bash"
            }
            
            // Unambiguous prefix markers
            let lower = t.lowercased()
            if t.hasPrefix("<?php")                                             { return "php" }
            if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html")   { return "xml" }
            if t.hasPrefix("<?xml") || (t.hasPrefix("<") && t.contains("</")) { return "xml" }
            
            // JSON — leading brace/bracket with quoted content
            if (t.hasPrefix("{") || t.hasPrefix("[")) && t.contains("\"") {
                return "json"
            }
            
            // SQL — leading keyword
            let up = t.uppercased()
            let sqlPrefixes = ["SELECT ", "INSERT INTO", "UPDATE ", "DELETE FROM",
                               "CREATE TABLE", "DROP TABLE", "ALTER TABLE", "WITH "]
            if sqlPrefixes.contains(where: { up.hasPrefix($0) }) { return "sql" }
            
            // C / C++ — #include is a dead giveaway; C++ tokens distinguish them
            if t.contains("#include") {
                return score(t, ["std::", "cout", "cin", "vector<", "nullptr", "template<", "::"]) >= 1
                ? "cpp" : "c"
            }
            
            // Swift — specific framework imports are unambiguous
            if score(t, ["import SwiftUI", "import Foundation", "import AppKit",
                         "import UIKit", "import Combine"]) >= 1 { return "swift" }
            if score(t, ["@State", "@Binding", "@Published", "@ObservedObject",
                         "@StateObject", "some View", "var body"]) >= 1 { return "swift" }
            if score(t, ["func ", "guard ", " -> ", "struct ", "enum ", "protocol ", "extension ", "var ", "let "]) >= 3 { return "swift" }
            // Swift range operators — "..<" is exclusive to Swift; "..." only counts when
            // used as a range (preceded by a word char), not as JS/TS spread (...arr)
            let hasSwiftRange = t.contains("..<") ||
            t.range(of: #"[\w\d]\.\.\."#, options: .regularExpression) != nil
            if hasSwiftRange &&
                score(t, ["func ", "var ", "let ", " -> ", "for "]) >= 2 { return "swift" }
            
            // Rust
            if score(t, ["fn ", "let mut ", "impl ", "pub struct", "pub fn",
                         "use std::", "Some(", "Ok(", "Err("]) >= 2 { return "rust" }
            
            // Go — `package` declaration anchors detection
            if t.contains("package ") &&
                score(t, ["func ", ":=", "fmt.", "var ", "type ", "interface{}", "map["]) >= 1 { return "go" }
            // Go — snippets without package: `func` + any Go-specific hint
            if t.contains("func ") &&
                score(t, [":=", "fmt.", "rand.", "defer ", "go func", "make(", "chan ", "goroutine"]) >= 1 { return "go" }
            if score(t, [":=", "fmt.", "rand.", "goroutine", "defer ", "go func"]) >= 2 { return "go" }
            
            // Kotlin — keywords not shared with Java
            if score(t, ["fun ", "val ", "data class", "companion object",
                         "suspend fun", "?.let", "?: "]) >= 2 { return "kotlin" }
            
            // Java
            if score(t, ["public class", "public static void main", "System.out.println",
                         "import java.", "@Override", "extends ", "implements "]) >= 2 { return "java" }
            
            // Python — colon-block style without braces separates it from JS/TS
            if score(t, ["def ", "elif ", "self.", "if __name__",
                         "print(", "lambda ", "import numpy", "import pandas"]) >= 2 { return "python" }
            if t.contains("def ") && t.contains(":") && !t.contains("{") { return "python" }
            
            // Perl — sub + Perl-specific sigils/builtins
            if t.contains("sub ") &&
                score(t, ["@_", "scalar(", "$_[", "my $", "use strict", "use warnings", "->{"]) >= 1 { return "perl" }
            if score(t, ["@_", "scalar(@", "my $", "use strict", "use warnings"]) >= 2 { return "perl" }
            
            // Ruby — `def`+`end` without braces is unambiguous (Python uses `:`, JS/Swift use `{}`)
            if t.contains("def ") && t.contains("end") && !t.contains("{") { return "ruby" }
            if score(t, ["def ", " do\n", " do |", "puts ", "require ",
                         "attr_accessor", ".each", "class << self", " end\n"]) >= 2 { return "ruby" }
            
            // TypeScript — type annotations checked before generic JS
            if score(t, ["interface ", ": string", ": number", ": boolean",
                         "export type ", "export interface", "readonly ", "<T>", " as "]) >= 2 { return "typescript" }
            
            // JavaScript
            if score(t, ["const ", "function ", "=>", "require(", "module.exports",
                         "console.log", "async ", "typeof "]) >= 2 { return "javascript" }
            
            // YAML — lines matching `key: value` pattern
            let yamlLines = lines.filter { line in
                let s = line.trimmingCharacters(in: .whitespaces)
                return !s.isEmpty && !s.hasPrefix("#") &&
                s.range(of: #"^[\w.-]+:\s"#, options: .regularExpression) != nil
            }
            if yamlLines.count >= 2 { return "yaml" }
            
            // CSS — specific property names, not generic punctuation
            if score(t, ["color:", "background:", "margin:", "padding:",
                         "display:", "font-size:", "border:", "flex:", "position:"]) >= 2 { return "css" }
            
            // Markdown
            if score(t, ["## ", "# ", "**", "```", "---", "> "]) >= 2 { return "markdown" }
            
            return "plaintext"
        }
        
        static func score(_ text: String, _ tokens: [String]) -> Int {
            tokens.filter { text.contains($0) }.count
        }
        
        @objc func gutterNeedsRedraw() {
            rulerView?.needsDisplay = true
        }
        
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
        
        // Feature 1 – cursor position
        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isApplyingProgrammaticChange else { return }
            guard let textView = notification.object as? NSTextView else { return }
            let nsText = textView.string as NSString
            let loc = textView.selectedRange().location
            let safeLen = min(loc, nsText.length)
            let prefix = nsText.substring(with: NSRange(location: 0, length: safeLen))
            let lineNum = prefix.components(separatedBy: "\n").count
            
            // Find start of the current line
            var lineStart = 0, lineEnd = 0, contentsEnd = 0
            nsText.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                                for: NSRange(location: safeLen, length: 0))
            let col = loc - lineStart + 1
            
            rulerView?.activeLine = lineNum
            rulerView?.needsDisplay = true
            parent.onCursorChange?(lineNum, col)
            
            highlightMatchingBracket(in: textView)
        }
        
        // MARK: - Bracket Highlighting
        
        private static let bracketPairs: [Character: Character] = [
            "(": ")", "{": "}", "[": "]",
            ")": "(", "}": "{", "]": "["
        ]
        private static let openBrackets: Set<Character> = ["(", "{", "["]
        private static let closeBrackets: Set<Character> = [")", "}", "]"]
        
        private func highlightMatchingBracket(in textView: NSTextView) {
            guard let storage = textView.textStorage else { return }
            
            // Clear previous bracket highlights
            for range in bracketHighlightRanges {
                if range.location + range.length <= storage.length {
                    storage.removeAttribute(.backgroundColor, range: range)
                }
            }
            bracketHighlightRanges = []
            
            let str = textView.string
            let loc = textView.selectedRange().location
            guard textView.selectedRange().length == 0 else { return }
            
            // Try char before cursor first, then char after cursor
            let candidates: [Int] = [loc - 1, loc].filter { $0 >= 0 && $0 < str.count }
            var foundAnchor: Int? = nil
            var foundChar: Character? = nil
            for pos in candidates {
                let idx = str.index(str.startIndex, offsetBy: pos)
                let ch = str[idx]
                if Self.bracketPairs[ch] != nil {
                    foundAnchor = pos
                    foundChar = ch
                    break
                }
            }
            
            guard let anchor = foundAnchor, let bracketChar = foundChar,
                  let matchChar = Self.bracketPairs[bracketChar] else { return }
            
            let isOpen = Self.openBrackets.contains(bracketChar)
            let chars = Array(str.unicodeScalars)
            var depth = 0
            var matchPos: Int? = nil
            
            if isOpen {
                for i in anchor..<chars.count {
                    let ch = Character(chars[i])
                    if ch == bracketChar { depth += 1 }
                    else if ch == matchChar {
                        depth -= 1
                        if depth == 0 { matchPos = i; break }
                    }
                }
            } else {
                for i in stride(from: anchor, through: 0, by: -1) {
                    let ch = Character(chars[i])
                    if ch == bracketChar { depth += 1 }
                    else if ch == matchChar {
                        depth -= 1
                        if depth == 0 { matchPos = i; break }
                    }
                }
            }
            
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let highlightColor = isDark
            ? NSColor(red: 0.3, green: 0.6, blue: 0.6, alpha: 0.45)
            : NSColor(red: 0.2, green: 0.7, blue: 0.7, alpha: 0.3)
            
            let anchorRange = NSRange(location: anchor, length: 1)
            storage.addAttribute(.backgroundColor, value: highlightColor, range: anchorRange)
            bracketHighlightRanges.append(anchorRange)
            
            if let mp = matchPos {
                let matchRange = NSRange(location: mp, length: 1)
                storage.addAttribute(.backgroundColor, value: highlightColor, range: matchRange)
                bracketHighlightRanges.append(matchRange)
            }
        }
        
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                handleTab(textView: textView, reverse: false)
                return true
            } else if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                handleTab(textView: textView, reverse: true)
                return true
            } else if commandSelector == #selector(NSResponder.deleteToBeginningOfLine(_:)) {
                let selected = textView.selectedRange()
                let text = textView.string as NSString
                var lineStart = 0, lineEnd = 0, contentsEnd = 0
                text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: selected)
                if selected.length == 0 && selected.location == lineStart && lineStart > 0 {
                    let range = NSRange(location: lineStart - 1, length: 1)
                    if textView.shouldChangeText(in: range, replacementString: "") {
                        textView.replaceCharacters(in: range, with: "")
                        textView.didChangeText()
                    }
                    return true
                }
                return false
            }
            return false
        }
        
        private func handleTab(textView: NSTextView, reverse: Bool) {
            let tabSize = SettingsManager.shared.tabSize
            let spaces = String(repeating: " ", count: tabSize)
            let selectedRange = textView.selectedRange()
            let text = textView.string as NSString
            
            var lineStart = 0, lineEnd = 0, contentsEnd = 0
            text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: selectedRange)
            
            let selectedText = text.substring(with: selectedRange)
            let isMultiline = selectedText.contains("\n")
            
            if isMultiline {
                let fullRange = NSRange(location: lineStart, length: lineEnd - lineStart)
                let selectedLines = text.substring(with: fullRange)
                var modifiedLines: [String] = []
                let lines = selectedLines.components(separatedBy: "\n")
                
                if reverse {
                    let indents = lines
                        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        .map { line -> Int in
                            if line.hasPrefix("\t") { return 1 }
                            return line.prefix(while: { $0 == " " }).count
                        }
                        .filter { $0 > 0 }
                    let toRemove = min(indents.min() ?? 0, tabSize)
                    for line in lines {
                        if line.hasPrefix("\t") {
                            modifiedLines.append(String(line.dropFirst()))
                        } else {
                            modifiedLines.append(String(line.dropFirst(min(line.prefix(while: { $0 == " " }).count, toRemove))))
                        }
                    }
                } else {
                    for line in lines { modifiedLines.append(spaces + line) }
                }
                
                let newText = modifiedLines.joined(separator: "\n")
                if textView.shouldChangeText(in: fullRange, replacementString: newText) {
                    textView.replaceCharacters(in: fullRange, with: newText)
                    textView.didChangeText()
                    let lengthDiff = (newText as NSString).length - (selectedLines as NSString).length
                    let textLength = (textView.string as NSString).length
                    let newLocation = min(selectedRange.location, textLength)
                    let newLength = max(0, selectedRange.length + lengthDiff)
                    let clampedLength = min(newLength, textLength - newLocation)
                    textView.setSelectedRange(NSRange(location: newLocation, length: clampedLength))
                }
            } else {
                if reverse {
                    let lineText = text.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))
                    let beforeCursor = lineText.prefix(selectedRange.location - lineStart)
                    if beforeCursor.hasSuffix(spaces) {
                        let removeRange = NSRange(location: selectedRange.location - tabSize, length: tabSize)
                        if textView.shouldChangeText(in: removeRange, replacementString: "") {
                            textView.replaceCharacters(in: removeRange, with: "")
                            textView.didChangeText()
                        }
                    } else if beforeCursor.hasSuffix("\t") {
                        let removeRange = NSRange(location: selectedRange.location - 1, length: 1)
                        if textView.shouldChangeText(in: removeRange, replacementString: "") {
                            textView.replaceCharacters(in: removeRange, with: "")
                            textView.didChangeText()
                        }
                    }
                } else {
                    if textView.shouldChangeText(in: selectedRange, replacementString: spaces) {
                        textView.replaceCharacters(in: selectedRange, with: spaces)
                        textView.didChangeText()
                    }
                }
            }
        }
    }
}

// MARK: - Shortcuts Popover

private struct ShortcutsPopover: View {
    private let sections: [(title: String, shortcuts: [(keys: String, action: String)])] = [
        ("Editing", [
            ("⌘ S",        "Save to clipboard"),
            ("⌘ F",        "Find & replace"),
            ("⌘ Z",        "Undo"),
            ("⌘ ⇧ Z",      "Redo"),
            ("⌘ A",        "Select all"),
            ("⌘ L",        "Select line"),
            ("⌘ D",        "Duplicate line"),
            ("⌘ ⇧ K",      "Delete line"),
            ("⌥ ↑",        "Move line up"),
            ("⌥ ↓",        "Move line down"),
            ("⌘ ⌫",        "Delete to line start"),
            ("Tab",        "Indent"),
            ("⇧ Tab",      "Unindent"),
        ]),
        ("View", [
            ("⌘ =",        "Increase font size"),
            ("⌘ −",        "Decrease font size"),
            ("⌘ 0",        "Reset font size"),
        ]),
        ("Transform", [
            ("⌘ ⇧ F",      "Format code"),
            ("⌘ ⇧ T",      "Trim whitespace"),
            ("⌘ ⇧ L",      "Lowercase"),
            ("⌘ ⇧ U",      "Uppercase"),
            ("⌘ ⇧ N",      "Normalize indentation"),
        ]),
        ("General", [
            ("Esc",        "Close editor"),
        ]),
    ]
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(AppTheme.tealSUI)
                            .textCase(.uppercase)
                        
                        ForEach(section.shortcuts, id: \.action) { shortcut in
                            HStack(spacing: 0) {
                                Text(shortcut.action)
                                    .font(.callout)
                                    .foregroundColor(.primary)
                                Spacer()
                                Text(shortcut.keys)
                                    .font(.callout.monospaced())
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                            }
                        }
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 280, height: 520)
    }
}

struct EditorView_Previews: PreviewProvider {
    static var previews: some View {
        EditorView(viewModel: EditorViewModel(), onSave: {}, onClose: {})
    }
}
