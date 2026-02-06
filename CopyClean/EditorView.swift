import SwiftUI
import AppKit

class LineNumberGutterView: NSView {
    weak var textView: NSTextView?
    private let gutterWidth: CGFloat = 40

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let scrollView = textView.enclosingScrollView else { return }

        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let bgColor = isDark
            ? NSColor(red: 36/255.0, green: 40/255.0, blue: 44/255.0, alpha: 1.0)
            : NSColor.controlBackgroundColor
        bgColor.setFill()
        bounds.fill()

        let font = textView.font ?? NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        let text = textView.string as NSString
        let visibleRect = scrollView.contentView.bounds
        let inset = textView.textContainerInset.height
        let viewHeight = bounds.height

        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: text.length))

        // Handle empty document
        if text.length == 0 {
            let numStr = "1" as NSString
            let strSize = numStr.size(withAttributes: attrs)
            numStr.draw(
                at: NSPoint(x: gutterWidth - strSize.width - 8, y: inset - visibleRect.origin.y),
                withAttributes: attrs
            )
            return
        }

        // Walk every line in the document, draw only if visible
        var lineNumber = 1
        var charIdx = 0
        while charIdx < text.length {
            let lineRange = text.lineRange(for: NSRange(location: charIdx, length: 0))
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: lineRange, actualCharacterRange: nil
            )

            let lineRect = layoutManager.lineFragmentRect(
                forGlyphAt: glyphRange.location, effectiveRange: nil
            )
            // Use only the first line fragment's y for the line number
            let y = lineRect.origin.y + inset - visibleRect.origin.y

            // Only draw if within visible gutter area
            if y + lineRect.height >= 0 && y < viewHeight {
                let numStr = "\(lineNumber)" as NSString
                let strSize = numStr.size(withAttributes: attrs)
                numStr.draw(at: NSPoint(x: gutterWidth - strSize.width - 8, y: y), withAttributes: attrs)
            }

            // Stop early if we're past the visible area
            if y > viewHeight { break }

            lineNumber += 1
            charIdx = NSMaxRange(lineRange)
        }

        // Trailing empty line after final newline
        if text.hasSuffix("\n") {
            let lastGlyphIndex = max(0, layoutManager.numberOfGlyphs - 1)
            let lastRect = layoutManager.lineFragmentRect(
                forGlyphAt: lastGlyphIndex, effectiveRange: nil
            )
            let y = lastRect.maxY + inset - visibleRect.origin.y
            if y + lastRect.height >= 0 && y < viewHeight {
                let numStr = "\(lineNumber)" as NSString
                let strSize = numStr.size(withAttributes: attrs)
                numStr.draw(at: NSPoint(x: gutterWidth - strSize.width - 8, y: y), withAttributes: attrs)
            }
        }
    }
}

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
    
    var body: some View {
        VStack(spacing: 0) {
            // Find/Replace bar
            if showFindBar {
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField("Find", text: $findText)
                            .textFieldStyle(.roundedBorder)
                            .focused($isFindFieldFocused)
                            .onChange(of: findText) { highlightMatches() }
                            .onSubmit { findNext() }
                        
                        Text("\(matchCount) found")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(minWidth: 50)
                        
                        Button(action: { findPrevious() }) {
                            Image(systemName: "chevron.up")
                        }
                        Button(action: { findNext() }) {
                            Image(systemName: "chevron.down")
                        }
                        Button(action: { closeFindBar() }) {
                            Image(systemName: "xmark")
                        }
                    }
                    
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.2.squarepath")
                            .foregroundColor(.secondary)
                        TextField("Replace", text: $replaceText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { replaceCurrent() }
                        
                        Button("Replace") { replaceCurrent() }
                        Button("All") { replaceAll() }
                    }
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                
                Divider()
            }
            
            // Editor area with integrated line number ruler
            CustomTextEditor(text: $viewModel.text, fontSize: settings.fontSize, onTextViewReady: { tv in
                textView = tv
            })
            .focused($isTextEditorFocused)
            
            Divider()
            
            // Button bar
            HStack {
                Spacer()
                
                Menu("Transform") {
                    Section("Whitespace") {
                        Button("Trim Whitespace") {
                            transform { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        }
                        .keyboardShortcut("t", modifiers: [.command, .shift])
                        
                        Button("Normalize Indentation") {
                            transform { text in
                                let tabWidth = 4
                                // Expand tabs to spaces for consistent measurement
                                let lines = text.components(separatedBy: "\n")
                                let expandedLines = lines.map { line -> String in
                                    line.replacingOccurrences(of: "\t", with: String(repeating: " ", count: tabWidth))
                                }
                                // Find minimum indentation of non-empty lines
                                let minIndent = expandedLines
                                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                                    .map { line in
                                        line.prefix(while: { $0 == " " }).count
                                    }
                                    .min() ?? 0
                                // Remove that amount from each expanded line
                                return expandedLines.map { line in
                                    if line.count >= minIndent {
                                        return String(line.dropFirst(minIndent))
                                    }
                                    return line
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
                        Button("lowercase") {
                            transform { $0.lowercased() }
                        }
                        .keyboardShortcut("l", modifiers: [.command, .shift])
                        
                        Button("UPPERCASE") {
                            transform { $0.uppercased() }
                        }
                        .keyboardShortcut("u", modifiers: [.command, .shift])
                        
                        Button("Title Case") {
                            transform { $0.capitalized }
                        }
                    }
                    
                    Section("Lines") {
                        Button("Sort Lines") {
                            transform {
                                $0.components(separatedBy: "\n")
                                    .sorted()
                                    .joined(separator: "\n")
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
                                $0.components(separatedBy: "\n")
                                    .reversed()
                                    .joined(separator: "\n")
                            }
                        }
                    }
                }
                
                Button("Cancel") {
                    closeFindBar()
                    onClose()
                }
                .keyboardShortcut(.escape, modifiers: [])
                
                Button("Save to Clipboard") {
                    onSave()
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(minWidth: 400, minHeight: 300)
        .background {
            Button("") {
                showFindBar.toggle()
                if showFindBar {
                    isFindFieldFocused = true
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            .hidden()
        }
        .onAppear {
            // Auto-focus the text editor when window appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isTextEditorFocused = true
            }
            // Monitor for font size and transform shortcuts
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

                // Cmd only (no shift/option/ctrl) — font size
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
                    default:
                        break
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
    
    private func closeFindBar() {
        showFindBar = false
        findText = ""
        replaceText = ""
        matchCount = 0
        // Clear highlighting
        if let tv = textView, let storage = tv.textStorage {
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.removeAttribute(.backgroundColor, range: fullRange)
        }
    }
    
    private func highlightMatches() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.backgroundColor, range: fullRange)
        
        guard !findText.isEmpty else {
            matchCount = 0
            return
        }
        
        let text = tv.string as NSString
        var count = 0
        var searchRange = NSRange(location: 0, length: text.length)
        
        while searchRange.location < text.length {
            let range = text.range(of: findText, options: .caseInsensitive, range: searchRange)
            if range.location == NSNotFound { break }
            
            storage.addAttribute(.backgroundColor, value: NSColor.yellow.withAlphaComponent(0.3), range: range)
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
        
        // Wrap around
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
        
        // Wrap around
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
    
    // Apply transformation through NSTextView for undo support
    private func transform(_ operation: (String) -> String) {
        guard let textView = textView else {
            // Fallback if no text view reference
            viewModel.text = operation(viewModel.text)
            return
        }
        
        let oldText = textView.string
        let newText = operation(oldText)
        
        // Disable automatic undo registration, ensure re-enable via defer
        textView.allowsUndo = false
        defer { textView.allowsUndo = true }
        
        // Apply the change
        textView.string = newText
        viewModel.text = newText
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        
        // Register undo if available
        guard let undoManager = textView.undoManager else { return }
        
        // Capture viewModel for closures
        let vm = viewModel
        
        // Register custom undo that doesn't select text
        undoManager.registerUndo(withTarget: textView) { tv in
            tv.allowsUndo = false
            tv.string = oldText
            vm.text = oldText
            tv.setSelectedRange(NSRange(location: 0, length: 0))
            tv.allowsUndo = true
            
            // Register redo
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

// Custom NSTextView wrapper with tab indentation support
struct CustomTextEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var onTextViewReady: ((NSTextView) -> Void)?

    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView

        // Configure text view
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.autoresizingMask = [.width, .height]
        textView.delegate = context.coordinator

        // Disable automatic substitutions
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false

        // Set initial text
        textView.string = text

        // Setup line number gutter
        let gutterView = LineNumberGutterView()
        gutterView.textView = textView

        // Layout with autolayout
        gutterView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(gutterView)
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            gutterView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            gutterView.topAnchor.constraint(equalTo: container.topAnchor),
            gutterView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            gutterView.widthAnchor.constraint(equalToConstant: 40),
            scrollView.leadingAnchor.constraint(equalTo: gutterView.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        context.coordinator.gutterView = gutterView
        context.coordinator.scrollView = scrollView

        // Observe scrolling, text changes, and frame changes to redraw gutter
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.gutterNeedsRedraw),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.gutterNeedsRedraw),
            name: NSText.didChangeNotification,
            object: textView
        )
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.gutterNeedsRedraw),
            name: NSView.frameDidChangeNotification,
            object: scrollView
        )

        // Provide reference to parent view
        DispatchQueue.main.async {
            onTextViewReady?(textView)
        }

        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.parent = self
        guard let scrollView = context.coordinator.scrollView,
              let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
            let gutter = context.coordinator.gutterView
            DispatchQueue.main.async {
                gutter?.display()
            }
        }

        // Apply font size changes
        let newFont = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        if textView.font != newFont {
            textView.font = newFont
            context.coordinator.gutterView?.needsDisplay = true
        }

        // Update background color for current appearance
        if NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            textView.backgroundColor = NSColor(red: 36/255.0, green: 40/255.0, blue: 44/255.0, alpha: 1.0)
            textView.insertionPointColor = .white
        } else {
            textView.backgroundColor = .textBackgroundColor
            textView.insertionPointColor = .textColor
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CustomTextEditor
        var gutterView: LineNumberGutterView?
        var scrollView: NSScrollView?

        init(_ parent: CustomTextEditor) {
            self.parent = parent
        }

        @objc func gutterNeedsRedraw() {
            gutterView?.display()
        }
        
        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
        
        // Handle tab key for indentation
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                handleTab(textView: textView, reverse: false)
                return true
            } else if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                handleTab(textView: textView, reverse: true)
                return true
            }
            return false
        }
        
        private func handleTab(textView: NSTextView, reverse: Bool) {
            let selectedRange = textView.selectedRange()
            let text = textView.string as NSString
            
            // Find the range of lines that are selected
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            
            text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: selectedRange)
            
            // Check if selection spans multiple lines
            let selectedText = text.substring(with: selectedRange)
            let isMultiline = selectedText.contains("\n")
            
            if isMultiline {
                // Multi-line selection: indent/unindent all selected lines
                let fullRange = NSRange(location: lineStart, length: lineEnd - lineStart)
                let selectedLines = text.substring(with: fullRange)
                
                var modifiedLines: [String] = []
                let lines = selectedLines.components(separatedBy: "\n")

                if reverse {
                    // Find minimum indentation across indented non-empty lines to outdent uniformly
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
                    for line in lines {
                        // Add indentation (4 spaces)
                        modifiedLines.append("    " + line)
                    }
                }
                
                let newText = modifiedLines.joined(separator: "\n")
                
                if textView.shouldChangeText(in: fullRange, replacementString: newText) {
                    textView.replaceCharacters(in: fullRange, with: newText)
                    textView.didChangeText()
                    
                    // Restore selection with clamping to valid range
                    let lengthDiff = (newText as NSString).length - (selectedLines as NSString).length
                    let textLength = (textView.string as NSString).length
                    let newLocation = min(selectedRange.location, textLength)
                    let newLength = max(0, selectedRange.length + lengthDiff)
                    let clampedLength = min(newLength, textLength - newLocation)
                    textView.setSelectedRange(NSRange(location: newLocation, length: clampedLength))
                }
            } else {
                // Single line or cursor: insert tab or perform unindent
                if reverse {
                    // Try to remove indentation before cursor
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
                    // Insert 4 spaces
                    if textView.shouldChangeText(in: selectedRange, replacementString: "    ") {
                        textView.replaceCharacters(in: selectedRange, with: "    ")
                        textView.didChangeText()
                    }
                }
            }
        }
    }
}

struct EditorView_Previews: PreviewProvider {
    static var previews: some View {
        EditorView(
            viewModel: EditorViewModel(),
            onSave: {},
            onClose: {}
        )
    }
}
