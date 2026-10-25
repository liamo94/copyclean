import SwiftUI
import AppKit
import Highlightr


private let abbreviatedRelativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
}()

private func formatRelativeDate(_ date: Date) -> String {
    abbreviatedRelativeFormatter.localizedString(for: date, relativeTo: Date())
}

struct HistoryView: View {
    @ObservedObject var historyManager: HistoryManager
    var onSelectEntry: (HistoryEntry) -> Void
    var onPaste: (HistoryEntry) -> Void = { _ in }
    var onClose: () -> Void
    
    @State private var selectedEntry: HistoryEntry?
    @State private var searchText = ""
    @State private var hoverCopy = false
    @State private var hoverPaste = false
    @State private var hoverEdit = false
    @State private var hoverDelete = false
    @State private var lastTapEntry: HistoryEntry.ID? = nil
    @State private var lastTapTime: Date = .distantPast
    @FocusState private var searchFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    
    /// Filters and orders entries. Callers compute this once and pass it along — it used to
    /// be a computed property re-evaluated (filter + sort) at every use during a render.
    private var filteredEntries: [HistoryEntry] {
        let base = searchText.isEmpty
        ? historyManager.entries
        : historyManager.entries.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
        // Pinned entries first, otherwise keeping recency order (stable, unlike sorted(by:))
        return base.filter(\.isPinned) + base.filter { !$0.isPinned }
    }
    
    var body: some View {
        let entries = filteredEntries
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar(entries: entries)
                Divider()
                detailPane
            }
            
            Divider()
            bottomBar
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear {
            selectedEntry = filteredEntries.first
            // The app delegate's key monitor hands this window's keys here. Registering a
            // handler (rather than a monitor per view) means a replaced window's view can't
            // keep handling keys for the new one.
            AppDelegate.shared?.historyKeyHandler = handleKey
        }
        .onChange(of: searchText) {
            // Keep the selection on a visible entry so Return/⌘↩ act on what's shown.
            let entries = filteredEntries
            if let selected = selectedEntry, entries.contains(where: { $0.id == selected.id }) { return }
            selectedEntry = entries.first
        }
        .onChange(of: historyManager.entries) {
            if let selected = selectedEntry {
                if !historyManager.entries.contains(where: { $0.id == selected.id }) {
                    selectedEntry = filteredEntries.first
                }
            } else {
                selectedEntry = filteredEntries.first
            }
        }
    }
    
    /// Every key pressed while Recent Snippets is the key window. Returns nil when handled.
    private func handleKey(_ event: NSEvent) -> NSEvent? {
        // Mid-composition with an input method (Japanese, Chinese…), Return and Esc belong
        // to the search field: they confirm or cancel the characters being composed.
        if let editor = event.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        // Ask AppKit rather than trusting `searchFocused` alone: type-to-search focuses the
        // field directly, and SwiftUI's copy of that can lag a keystroke behind.
        let inSearch = searchFocused || (event.window?.firstResponder as? NSTextView)?.isFieldEditor == true
        switch event.keyCode {
        case 53: // Escape clears a search first, then closes
            if !searchText.isEmpty { searchText = ""; return nil }
            onClose()
            return nil
        case 125 where mods.isEmpty: leaveSearch(event); navigateSelection(by: +1); return nil  // ↓
        case 126 where mods.isEmpty: leaveSearch(event); navigateSelection(by: -1); return nil  // ↑
        case 36, 76: // Return edits, ⌘Return pastes — from the search field too
            if let entry = selectedEntry {
                mods == .command ? onPaste(entry) : onSelectEntry(entry)
            }
            return nil
        case 51 where mods.isEmpty && !inSearch: // Delete
            if let entry = selectedEntry { deleteEntry(entry) }
            return nil
        default: break
        }
        if mods == .command, let key {
            switch key {
            case "w": onClose(); return nil
            case "c": if let entry = selectedEntry { copyAndClose(entry) }; return nil
            case "f": searchFocused = true; return nil
            case "p": if let entry = selectedEntry { historyManager.togglePin(entry) }; return nil
            case "z" where !inSearch: undoDelete(); return nil
            case "1"..."9":
                let entries = filteredEntries
                if let n = Int(key), entries.indices.contains(n - 1) { onPaste(entries[n - 1]) }
                return nil
            default:
                // App-wide shortcuts and the search field's own (⌘A, ⌘V…) still work; anything
                // else would only beep at the list.
                return inSearch || "qhm,".contains(key) ? event : nil
            }
        }
        guard !inSearch else { return event }
        // Typing anywhere searches: focus the field now and let it take this key itself, so
        // no keystroke can land before the field is ready. A leading space is ignored — it
        // would match nearly everything.
        if mods.subtracting(.shift).isEmpty, let chars = event.characters, !chars.isEmpty,
           chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }) {
            if searchText.isEmpty, chars.allSatisfy(\.isWhitespace) { return nil }
            guard let window = event.window, let field = Self.searchField(in: window.contentView) else { return nil }
            window.makeFirstResponder(field)
            // Becoming first responder selects the field's text; type after it instead.
            (field.currentEditor() as? NSTextView)?.moveToEndOfDocument(nil)
            return event
        }
        // List navigation keys reach the list; anything else would only beep.
        let listKeys: Set<UInt16> = [48, 115, 116, 119, 121, 123, 124] // Tab, Home, PgUp, End, PgDn, ←, →
        return listKeys.contains(event.keyCode) ? event : nil
    }

    /// Moves focus off the search field, back to the list.
    private func leaveSearch(_ event: NSEvent) {
        searchFocused = false
        if (event.window?.firstResponder as? NSTextView)?.isFieldEditor == true {
            event.window?.makeFirstResponder(nil)
        }
    }

    /// The search box's text field (the only editable one in the window).
    private static func searchField(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for subview in view.subviews {
            if let field = searchField(in: subview) { return field }
        }
        return nil
    }

    private func undoDelete() {
        guard let entry = historyManager.undoDelete() else { return }
        searchText = ""
        selectedEntry = entry
        AppDelegate.shared?.showToast("Restored")
    }

    private func navigateSelection(by offset: Int) {
        let entries = filteredEntries
        guard !entries.isEmpty else { return }
        if let current = selectedEntry, let idx = entries.firstIndex(where: { $0.id == current.id }) {
            let next = idx + offset
            if next >= 0 && next < entries.count { selectedEntry = entries[next] }
        } else {
            selectedEntry = offset > 0 ? entries.first : entries.last
        }
    }
    
    // MARK: - Bottom Bar
    
    private var bottomBar: some View {
        HStack(spacing: 0) {
            // Left: timestamp + stats
            if let entry = selectedEntry {
                let meta = historyManager.meta(for: entry)
                HStack(spacing: 10) {
                    Text(formatRelativeDate(entry.timestamp))
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                    
                    barDivider
                    
                    statPill("\(meta.lines)", label: "lines")
                    statPill("\(meta.words)", label: "words")
                    statPill("\(meta.chars)", label: "chars")
                }
                .padding(.horizontal, 14)
            } else {
                Spacer()
            }
            
            Spacer()
            
            if selectedEntry != nil {
                // Delete
                Button {
                    if let entry = selectedEntry { deleteEntry(entry) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                            .foregroundColor(hoverDelete ? .red.opacity(0.8) : .secondary.opacity(0.7))
                            .font(.system(size: 11))
                        Text("Delete")
                            .foregroundColor(hoverDelete ? .primary : .primary.opacity(0.75))
                            .font(.system(size: 12))
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(hoverDelete ? Color.red.opacity(0.08) : Color.clear)
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .onHover { hoverDelete = $0 }
                
                barDivider
                
                // Copy
                Button {
                    if let entry = selectedEntry { copyAndClose(entry) }
                } label: {
                    bottomAction("Copy", shortcut: "⌘C", hovered: hoverCopy)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .onHover { hoverCopy = $0 }
                
                barDivider
                
                // Paste
                Button {
                    if let entry = selectedEntry { onPaste(entry) }
                } label: {
                    bottomAction("Paste", shortcut: "⌘↩", hovered: hoverPaste)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .onHover { hoverPaste = $0 }
                .help("Paste into the app you came from (⌘↩, or ⌘1–⌘9 for the first nine)")
                
                barDivider
                
                // Edit
                Button {
                    if let entry = selectedEntry { onSelectEntry(entry) }
                } label: {
                    HStack(spacing: 6) {
                        Text("Edit")
                            .fontWeight(.medium)
                            .foregroundColor(hoverEdit ? AppTheme.tealSUI : AppTheme.tealSUI.opacity(0.8))
                        Text("↵")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(hoverEdit ? .secondary : .secondary.opacity(0.6))
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(hoverEdit ? Color.secondary.opacity(0.12) : Color.clear)
                    .cornerRadius(5)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .onHover { hoverEdit = $0 }
            }
        }
        .frame(height: 36)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    
    private var barDivider: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.2))
            .frame(width: 1, height: 16)
    }
    
    @ViewBuilder
    private func bottomAction(_ label: String, shortcut: String, hovered: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .foregroundColor(hovered ? .primary : .primary.opacity(0.75))
            Text(shortcut)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(hovered ? .secondary : .secondary.opacity(0.6))
        }
        .font(.system(size: 12))
        .fixedSize()
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(hovered ? Color.secondary.opacity(0.12) : Color.clear)
        .cornerRadius(5)
    }
    
    @ViewBuilder
    private func statPill(_ value: String, label: String) -> some View {
        HStack(spacing: 3) {
            Text(value)
                .monospacedDigit()
                .foregroundColor(AppTheme.tealSUI)
            Text(label)
                .foregroundColor(.secondary)
        }
        .font(.caption)
    }
    
    // MARK: - Sidebar
    
    private func sidebar(entries: [HistoryEntry]) -> some View {
        VStack(spacing: 0) {
            searchBar
            
            Divider()
            
            if entries.isEmpty {
                emptyState(
                    icon: searchText.isEmpty ? "doc.text" : "magnifyingglass",
                    title: searchText.isEmpty ? "No History" : "No Results",
                    subtitle: searchText.isEmpty ? "Saved edits will appear here" : "No entries match your search — Esc clears it"
                )
            } else {
                ScrollViewReader { proxy in
                    List(selection: $selectedEntry) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            let isSelected = selectedEntry?.id == entry.id
                            HistoryEntryRow(entry: entry, meta: historyManager.meta(for: entry), isSelected: isSelected,
                                            pasteShortcut: index < 9 ? "⌘\(index + 1)" : nil)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    NSApp.keyWindow?.makeFirstResponder(nil)
                                    let now = Date()
                                    if lastTapEntry == entry.id && now.timeIntervalSince(lastTapTime) < 0.4 {
                                        onSelectEntry(entry)
                                    } else {
                                        selectedEntry = entry
                                        lastTapEntry = entry.id
                                        lastTapTime = now
                                    }
                                }
                                .listRowBackground(
                                    isSelected
                                    ? AppTheme.tealSUI.cornerRadius(6)
                                    : Color.clear.cornerRadius(6)
                                )
                                .contextMenu {
                                    Button("Paste") { onPaste(entry) }
                                    Button("Copy to Clipboard") { copyAndClose(entry) }
                                    Button("Edit") { onSelectEntry(entry) }
                                    Divider()
                                    Button(entry.isPinned ? "Unpin (⌘P)" : "Pin (⌘P)") {
                                        historyManager.togglePin(entry)
                                    }
                                    Divider()
                                    Button("Delete", role: .destructive) { deleteEntry(entry) }
                                }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                deleteEntry(entries[index])
                            }
                        }
                    }
                    .listStyle(.sidebar)
                    .onChange(of: selectedEntry) { _, entry in
                        if let entry { proxy.scrollTo(entry.id) }
                    }
                    .onChange(of: historyManager.entries) {
                        if let entry = selectedEntry {
                            DispatchQueue.main.async { proxy.scrollTo(entry.id) }
                        }
                    }
                }
            }
        }
        .frame(width: 260)
    }
    
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(AppTheme.tealSUI)
                .imageScale(.small)
            TextField("Type to search…", text: $searchText)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !searchText.isEmpty {
                Button(action: { searchText = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .imageScale(.small)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }
    
    // MARK: - Detail Pane
    
    @ViewBuilder
    private var detailPane: some View {
        if let entry = selectedEntry {
            let lang = entry.language ?? historyManager.meta(for: entry).detectedLanguage
            // No .id(entry.id): recreating the view per selection built a fresh Highlightr
            // (a new JS context evaluating ~1 MB of highlight.js) on every arrow key.
            SyntaxPreviewView(entryID: entry.id, text: entry.text, language: lang, isDark: colorScheme == .dark)
        } else {
            emptyState(
                icon: "sidebar.left",
                title: "Select an Entry",
                subtitle: "Choose a clipboard entry from the list"
            )
        }
    }
    
    // MARK: - Helpers
    
    @ViewBuilder
    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .thin))
                .foregroundColor(AppTheme.tealSUI.opacity(0.5))
            Text(title)
                .font(.headline)
                .foregroundColor(.secondary)
            Text(subtitle)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func copyAndClose(_ entry: HistoryEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        onClose()
        AppDelegate.shared?.showToast("Copied to clipboard")
    }
    
    private func deleteEntry(_ entry: HistoryEntry) {
        if selectedEntry?.id == entry.id {
            if let index = filteredEntries.firstIndex(where: { $0.id == entry.id }) {
                if index > 0 {
                    selectedEntry = filteredEntries[index - 1]
                } else if index + 1 < filteredEntries.count {
                    selectedEntry = filteredEntries[index + 1]
                } else {
                    selectedEntry = nil
                }
            } else {
                selectedEntry = nil
            }
        }
        historyManager.deleteEntry(entry)
        AppDelegate.shared?.showToast("Deleted — ⌘Z to undo")
    }
}

// MARK: - Row

struct HistoryEntryRow: View {
    let entry: HistoryEntry
    let meta: HistoryEntryMeta
    var isSelected: Bool = false
    /// "⌘1"…"⌘9" for the first nine rows, which those keys paste.
    var pasteShortcut: String? = nil
    
    private var preview: String { meta.preview }
    private var secondLine: String? { meta.secondLine }
    private var detectedLanguage: String { entry.language ?? meta.detectedLanguage }
    
    private var languageLabel: String {
        switch detectedLanguage {
        case "plaintext":   return ""
        case "javascript":  return "JS"
        case "typescript":  return "TS"
        case "xml":         return "HTML"
        case "cpp":         return "C++"
        default:            return detectedLanguage.prefix(1).uppercased() + detectedLanguage.dropFirst()
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(preview)
                .font(.system(.body))
                .lineLimit(1)
            
            if let second = secondLine {
                Text(second)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            HStack(spacing: 4) {
                if entry.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundColor(AppTheme.tealSUI)
                }
                if entry.isScratch {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .help("Saved from a scratch pad")
                }
                Circle()
                    .fill(AppTheme.tealSUI.opacity(isSelected ? 0.9 : 0.4))
                    .frame(width: 5, height: 5)
                Text(formatRelativeDate(entry.timestamp))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                if !languageLabel.isEmpty {
                    Text("·")
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.5))
                    Text(languageLabel)
                        .font(.system(size: 9, weight: entry.language != nil ? .semibold : .regular))
                        .foregroundColor(entry.language != nil
                                         ? (isSelected ? AppTheme.tealSUI.opacity(0.9) : AppTheme.tealSUI)
                                         : .secondary)
                }
                if let pasteShortcut {
                    Spacer(minLength: 4)
                    Text(pasteShortcut)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Syntax Preview

struct SyntaxPreviewView: NSViewRepresentable {
    let entryID: UUID
    let text: String
    let language: String
    let isDark: Bool
    
    /// One highlighter shared by every preview — creating a Highlightr evaluates ~1 MB of
    /// highlight.js in a fresh JSContext (~20ms), far too slow to do per selection.
    private static let sharedHighlightr: Highlightr? = {
        let h = Highlightr()
        h?.theme.setCodeFont(.monospacedSystemFont(ofSize: 12, weight: .regular))
        return h
    }()
    
    
    class Coordinator {
        let codeStorage: NSTextStorage
        var shownEntryID: UUID?
        var shownLanguage: String?
        var appliedTheme: String?
        
        init() {
            if let h = SyntaxPreviewView.sharedHighlightr {
                codeStorage = CodeAttributedString(highlightr: h)
            } else {
                codeStorage = NSTextStorage()
            }
        }
    }
    
    func makeCoordinator() -> Coordinator { Coordinator() }
    
    func makeNSView(context: Context) -> NSScrollView {
        let textStorage = context.coordinator.codeStorage
        
        let layoutManager = NSLayoutManager()
        layoutManager.allowsNonContiguousLayout = true
        textStorage.addLayoutManager(layoutManager)
        
        let textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        
        let textView = NSTextView(frame: .zero, textContainer: textContainer)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.autoresizingMask = NSView.AutoresizingMask.width
        textView.isAutomaticQuoteSubstitutionEnabled = false
        
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        return scrollView
    }
    
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        guard let textView = scrollView.documentView as? NSTextView else { return }
        
        let theme = SettingsManager.shared.themeName(isDark: isDark)
        let themeChanged = coordinator.appliedTheme != theme
        if themeChanged, let h = Self.sharedHighlightr {
            coordinator.appliedTheme = theme
            h.setTheme(to: theme)
            h.theme.setCodeFont(.monospacedSystemFont(ofSize: 12, weight: .regular))
            let bg = h.theme.themeBackgroundColor ?? .textBackgroundColor
            textView.backgroundColor = bg
            scrollView.backgroundColor = bg
        }
        
        guard let storage = coordinator.codeStorage as? CodeAttributedString else {
            if coordinator.shownEntryID != entryID {
                coordinator.shownEntryID = entryID
                textView.string = text
            }
            return
        }
        // Huge entries: plain text, for the same reason as the editor.
        let lang = text.utf16.count > 1_000_000 ? "plaintext" : language
        if coordinator.shownEntryID != entryID {
            coordinator.shownEntryID = entryID
            coordinator.shownLanguage = lang
            // Swap text with highlighting off, then highlight once with the right language.
            storage.language = nil
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
            storage.language = lang
            textView.scroll(.zero)
        } else if coordinator.shownLanguage != lang || themeChanged {
            coordinator.shownLanguage = lang
            storage.language = nil
            storage.language = lang
        }
    }
}
