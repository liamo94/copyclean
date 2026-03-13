import SwiftUI
import AppKit
import Highlightr

// MARK: - Theme

private enum AppTheme {
    static let teal    = NSColor(red: 0.165, green: 0.483, blue: 0.420, alpha: 1.0)
    static let tealSUI = Color(red: 0.165, green: 0.483, blue: 0.420)
    static let editorDarkBG = NSColor(red: 0.11, green: 0.13, blue: 0.13, alpha: 1.0)
    static let gutterDarkBG = NSColor(red: 0.09, green: 0.11, blue: 0.11, alpha: 1.0)
}

// MARK: - Line Number Gutter

class LineNumberRulerView: NSRulerView {
    var fontSize: CGFloat = NSFont.systemFontSize

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

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize * 0.85, weight: .regular),
            .foregroundColor: isDark
                ? AppTheme.teal.withAlphaComponent(0.55)
                : AppTheme.teal.withAlphaComponent(0.65)
        ]

        layoutManager.ensureLayout(for: container)

        let text = textView.string as NSString
        let len  = text.length
        let inset = textView.textContainerInset.height
        let width = requiredThickness

        func drawNum(_ n: Int, _ containerY: CGFloat) {
            let s = "\(n)" as NSString
            let sz = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: width - sz.width - 10, y: containerY + inset), withAttributes: attrs)
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

        // Only draw the extra line if text actually ends with a newline
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
    @State private var currentLanguage = "plaintext"
    @State private var showShortcuts = false

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

            CustomTextEditor(text: $viewModel.text, language: $currentLanguage, fontSize: settings.fontSize, onTextViewReady: { tv in
                textView = tv
            })
            .focused($isTextEditorFocused)

            Divider()

            bottomBar
        }
        .frame(minWidth: 520, minHeight: 380)
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
                if matchCount > 0 {
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

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            let stats = textStats
            HStack(spacing: 10) {
                statPill(value: "\(stats.lines)", label: "lines")
                statPill(value: "\(stats.words)", label: "words")
                statPill(value: "\(stats.chars)", label: "chars")
            }

            Spacer()

            Menu("Transform") {
                Menu("Language: \(Self.languages.first { $0.id == currentLanguage }?.label ?? currentLanguage)") {
                    ForEach(Self.languages, id: \.id) { lang in
                        Button {
                            if lang.id == "auto" {
                                currentLanguage = CustomTextEditor.Coordinator.guessLanguage(viewModel.text)
                            } else {
                                currentLanguage = lang.id
                            }
                        } label: {
                            HStack {
                                Text(lang.label)
                                if currentLanguage == lang.id {
                                    Spacer()
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }

                Divider()

                Section("Whitespace") {
                    Button("Trim Whitespace") {
                        transform { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    .keyboardShortcut("t", modifiers: [.command, .shift])

                    Button("Normalize Indentation") {
                        transform { text in
                            let tabWidth = 4
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
                        transform { $0.replacingOccurrences(of: "\t", with: "    ") }
                    }
                    Button("Spaces → Tabs") {
                        transform { $0.replacingOccurrences(of: "    ", with: "\t") }
                    }
                }

                Section("Case") {
                    Button("lowercase") { transform { $0.lowercased() } }
                        .keyboardShortcut("l", modifiers: [.command, .shift])
                    Button("UPPERCASE") { transform { $0.uppercased() } }
                        .keyboardShortcut("u", modifiers: [.command, .shift])
                    Button("Title Case") { transform { $0.capitalized } }
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
            }

            Button("Cancel") {
                closeFindBar()
                onClose()
            }
            .keyboardShortcut(.escape, modifiers: [])

            Button("Save to Clipboard") { onSave() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.tealSUI)
                .help("Save to Clipboard (⌘S)")

            Button {
                showShortcuts.toggle()
            } label: {
                Image(systemName: "keyboard")
                    .foregroundColor(showShortcuts ? AppTheme.tealSUI : .secondary)
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showShortcuts, arrowEdge: .top) {
                ShortcutsPopover()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func statPill(value: String, label: String) -> some View {
        HStack(spacing: 3) {
            Text(value)
                .monospacedDigit()
                .foregroundColor(AppTheme.tealSUI)
            Text(label)
                .foregroundColor(.secondary)
        }
        .font(.caption)
    }

    // MARK: - Find Logic

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
        // Whether the current line has a trailing newline (le points past it, ce points before it)
        let currentHasNewline = le > ce

        if up {
            guard ls > 0 else { return }
            var pls = 0, ple = 0, pce = 0
            text.getLineStart(&pls, end: &ple, contentsEnd: &pce, for: NSRange(location: ls - 1, length: 0))
            let prevLine = text.substring(with: NSRange(location: pls, length: pce - pls))
            // swapRange covers: prevLine+\n+currentLine+(optional \n)
            // replacement must cover the same span
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
            // swapRange covers: currentLine+\n+nextLine+(optional \n)
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

    private func highlightMatches() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.backgroundColor, range: fullRange)

        guard !findText.isEmpty else { matchCount = 0; return }

        let text = tv.string as NSString
        var count = 0
        var searchRange = NSRange(location: 0, length: text.length)

        while searchRange.location < text.length {
            let range = text.range(of: findText, options: .caseInsensitive, range: searchRange)
            if range.location == NSNotFound { break }
            storage.addAttribute(.backgroundColor, value: AppTheme.teal.withAlphaComponent(0.28), range: range)
            count += 1
            searchRange.location = range.location + range.length
            searchRange.length = text.length - searchRange.location
        }
        matchCount = count
    }

    private func findNext() {
        guard let tv = textView, !findText.isEmpty else { return }
        let text = tv.string as NSString
        let currentPos = tv.selectedRange().location + tv.selectedRange().length
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

    private func findPrevious() {
        guard let tv = textView, !findText.isEmpty else { return }
        let text = tv.string as NSString
        let currentPos = tv.selectedRange().location
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

    private func replaceCurrent() {
        guard let tv = textView, !findText.isEmpty else { return }
        let selectedText = (tv.string as NSString).substring(with: tv.selectedRange())
        if selectedText.caseInsensitiveCompare(findText) == .orderedSame {
            tv.insertText(replaceText, replacementRange: tv.selectedRange())
            highlightMatches()
        }
        findNext()
    }

    private func replaceAll() {
        guard !findText.isEmpty else { return }
        transform { text in
            text.replacingOccurrences(of: findText, with: replaceText, options: .caseInsensitive)
        }
        highlightMatches()
    }

    private func transform(_ operation: (String) -> String) {
        guard let textView = textView else {
            viewModel.text = operation(viewModel.text)
            return
        }
        let oldText = textView.string
        let newText = operation(oldText)
        textView.allowsUndo = false
        defer { textView.allowsUndo = true }
        textView.string = newText
        viewModel.text = newText
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        guard let undoManager = textView.undoManager else { return }
        let vm = viewModel
        undoManager.registerUndo(withTarget: textView) { tv in
            tv.allowsUndo = false
            tv.string = oldText
            vm.text = oldText
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            tv.allowsUndo = true
            undoManager.registerUndo(withTarget: tv) { tv2 in
                tv2.allowsUndo = false
                tv2.string = newText
                vm.text = newText
                tv2.setSelectedRange(NSRange(location: 0, length: 0))
                tv2.allowsUndo = true
            }
        }
    }
}

// MARK: - Custom Text Editor

struct CustomTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var language: String
    var fontSize: CGFloat
    var onTextViewReady: ((NSTextView) -> Void)?

    func makeNSView(context: Context) -> NSView {
        let highlightr = Highlightr()!
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

        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.autoresizingMask = [.width, .height]
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

        // Use NSRulerView — lives inside the scroll view, shares its coordinate system,
        // and redraws as part of the scroll view's own display cycle (no layer ghosting).
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

        let coordinator = context.coordinator
        DispatchQueue.main.async {
            onTextViewReady?(textView)
            coordinator.detectAndApplyLanguage(for: text)
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.parent = self
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
        if context.coordinator.rulerView?.fontSize != fontSize {
            context.coordinator.rulerView?.fontSize = fontSize
            context.coordinator.highlightr?.theme.setCodeFont(newFont)
        }

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let theme = isDark ? "atom-one-dark" : "xcode"
        if context.coordinator.highlightr?.theme.themeBackgroundColor != nil {
            context.coordinator.highlightr?.setTheme(to: theme)
            context.coordinator.highlightr?.theme.setCodeFont(newFont)
        }
        if isDark {
            textView.backgroundColor = context.coordinator.highlightr?.theme.themeBackgroundColor ?? AppTheme.editorDarkBG
            textView.insertionPointColor = AppTheme.teal
        } else {
            textView.backgroundColor = context.coordinator.highlightr?.theme.themeBackgroundColor ?? .textBackgroundColor
            textView.insertionPointColor = NSColor(AppTheme.tealSUI)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CustomTextEditor
        var rulerView: LineNumberRulerView?
        var scrollView: NSScrollView?
        var highlightr: Highlightr?
        var codeStorage: CodeAttributedString?

        init(_ parent: CustomTextEditor) { self.parent = parent }

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

            // Shell
            if t.hasPrefix("#!/bin/bash") || t.hasPrefix("#!/bin/sh") || t.hasPrefix("#!/usr/bin/env bash") {
                return "bash"
            }
            // HTML
            if t.lowercased().hasPrefix("<!doctype html") || t.hasPrefix("<html") {
                return "xml"
            }
            // XML
            if t.hasPrefix("<?xml") || (t.hasPrefix("<") && t.contains("</")) {
                return "xml"
            }
            // JSON
            if (t.hasPrefix("{") || t.hasPrefix("[")) && (t.contains("\"") || t.contains(":")) {
                return "json"
            }
            // SQL
            let up = t.uppercased()
            if up.hasPrefix("SELECT ") || up.hasPrefix("INSERT ") || up.hasPrefix("UPDATE ") || up.hasPrefix("DELETE ") || up.hasPrefix("CREATE TABLE") {
                return "sql"
            }
            // Swift
            if score(t, ["import Foundation", "import SwiftUI", "import AppKit", "func ", "var ", "let ", "struct ", "class ", "protocol ", "enum ", " -> "]) >= 3 {
                return "swift"
            }
            // Python
            if score(t, ["def ", "import ", "print(", "elif ", "self.", "class ", "if __name__"]) >= 2 {
                return "python"
            }
            // TypeScript
            if score(t, ["interface ", ": string", ": number", ": boolean", " as ", "export ", "import "]) >= 2 {
                return "typescript"
            }
            // JavaScript
            if score(t, ["const ", "function ", "=>", "require(", "module.exports", "console.log", "async ", "await ", "typeof ", "instanceof ", "var ", "return "]) >= 2 {
                return "javascript"
            }
            // CSS
            if score(t, ["{", ":", ";", "px", "rem", "color", "margin", "padding"]) >= 4 && !t.hasPrefix("{") {
                return "css"
            }
            // Markdown
            if score(t, ["## ", "# ", "**", "- [", "```", "[](", "---"]) >= 2 {
                return "markdown"
            }
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
                    // At start of line — delete the newline to merge with the line above
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
                    let toRemove = min(indents.min() ?? 0, 4)
                    for line in lines {
                        if line.hasPrefix("\t") {
                            modifiedLines.append(String(line.dropFirst()))
                        } else {
                            modifiedLines.append(String(line.dropFirst(min(line.prefix(while: { $0 == " " }).count, toRemove))))
                        }
                    }
                } else {
                    for line in lines { modifiedLines.append("    " + line) }
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
                    if beforeCursor.hasSuffix("    ") {
                        let removeRange = NSRange(location: selectedRange.location - 4, length: 4)
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
                    if textView.shouldChangeText(in: selectedRange, replacementString: "    ") {
                        textView.replaceCharacters(in: selectedRange, with: "    ")
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
        .frame(width: 280)
    }
}

struct EditorView_Previews: PreviewProvider {
    static var previews: some View {
        EditorView(viewModel: EditorViewModel(), onSave: {}, onClose: {})
    }
}
