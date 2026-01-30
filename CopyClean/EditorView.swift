import SwiftUI
import AppKit

struct LineNumberView: View {
    let text: String
    
    private var lineCount: Int {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return max(lines.count, 1)
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(1...lineCount, id: \.self) { lineNumber in
                    Text("\(lineNumber)")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(height: 19.5) // Match TextEditor line height
                        .padding(.trailing, 8)
                }
            }
            .padding(.top, 12)
        }
        .scrollDisabled(true)
    }
}

struct EditorView: View {
    @ObservedObject var viewModel: EditorViewModel
    var onSave: () -> Void
    var onClose: () -> Void
    @FocusState private var isTextEditorFocused: Bool
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
            
            // Editor area with line numbers
            HStack(alignment: .top, spacing: 0) {
                // Line numbers
                LineNumberView(text: viewModel.text)
                    .frame(width: 40)
                    .background(Color(nsColor: .controlBackgroundColor))
                
                Divider()
                
                // Custom text editor with tab support
                CustomTextEditor(text: $viewModel.text, onTextViewReady: { tv in
                    textView = tv
                })
                .focused($isTextEditorFocused)
            }
            
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
                                let lines = text.components(separatedBy: "\n")
                                // Find minimum indentation of non-empty lines
                                let minIndent = lines
                                    .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                                    .map { line in
                                        line.prefix(while: { $0 == " " || $0 == "\t" }).count
                                    }
                                    .min() ?? 0
                                // Remove that amount from each line
                                return lines.map { line in
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
        
        guard let undoManager = textView.undoManager else { return }
        
        // Disable automatic undo registration
        textView.allowsUndo = false
        
        // Apply the change
        textView.string = newText
        viewModel.text = newText
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        
        // Re-enable undo
        textView.allowsUndo = true
        
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
    var onTextViewReady: ((NSTextView) -> Void)?
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        let textView = scrollView.documentView as! NSTextView
        
        // Configure text view
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.autoresizingMask = [.width, .height]
        textView.delegate = context.coordinator
        
        // Set background color for dark mode
        if NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            textView.backgroundColor = NSColor(red: 36/255.0, green: 40/255.0, blue: 44/255.0, alpha: 1.0)
            textView.insertionPointColor = .white
        }
        
        // Disable automatic substitutions
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        
        // Set initial text
        textView.string = text
        
        // Provide reference to parent view
        DispatchQueue.main.async {
            onTextViewReady?(textView)
        }
        
        return scrollView
    }
    
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let textView = scrollView.documentView as! NSTextView
        if textView.string != text {
            textView.string = text
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CustomTextEditor
        
        init(_ parent: CustomTextEditor) {
            self.parent = parent
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
            let isMultiline = selectedText.contains("\n") || selectedRange.length > 0
            
            if isMultiline {
                // Multi-line selection: indent/unindent all selected lines
                let fullRange = NSRange(location: lineStart, length: lineEnd - lineStart)
                let selectedLines = text.substring(with: fullRange)
                
                var modifiedLines: [String] = []
                let lines = selectedLines.components(separatedBy: "\n")
                
                for line in lines {
                    if reverse {
                        // Remove one level of indentation (4 spaces or 1 tab)
                        if line.hasPrefix("    ") {
                            modifiedLines.append(String(line.dropFirst(4)))
                        } else if line.hasPrefix("\t") {
                            modifiedLines.append(String(line.dropFirst()))
                        } else {
                            modifiedLines.append(line)
                        }
                    } else {
                        // Add indentation (4 spaces)
                        modifiedLines.append("    " + line)
                    }
                }
                
                let newText = modifiedLines.joined(separator: "\n")
                
                if textView.shouldChangeText(in: fullRange, replacementString: newText) {
                    textView.replaceCharacters(in: fullRange, with: newText)
                    textView.didChangeText()
                    
                    // Restore selection
                    let lengthDiff = (newText as NSString).length - (selectedLines as NSString).length
                    let newRange = NSRange(location: selectedRange.location, length: selectedRange.length + lengthDiff)
                    textView.setSelectedRange(newRange)
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
