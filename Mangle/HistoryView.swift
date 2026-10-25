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
    var onClose: () -> Void
    
    @State private var selectedEntry: HistoryEntry?
    @State private var searchText = ""
    @State private var hoverCopy = false
    @State private var hoverEdit = false
    @State private var hoverDelete = false
    @State private var lastTapEntry: HistoryEntry.ID? = nil
    @State private var lastTapTime: Date = .distantPast
    @State private var keyMonitor: Any? = nil
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
            syncSelectedEntry()
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
                guard NSApp.keyWindow?.identifier?.rawValue == "history" else { return event }
                switch event.keyCode {
                case 125: searchFocused = false; navigateSelection(by: +1); return nil  // ↓
                case 126: searchFocused = false; navigateSelection(by: -1); return nil  // ↑
                case 36 where searchFocused: searchFocused = false; return nil          // Return
                default: return event
                }
            }
        }
        .onDisappear {
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        }
        .onChange(of: selectedEntry) { syncSelectedEntry() }
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
                .keyboardShortcut("c", modifiers: .command)
                .padding(.horizontal, 8)
                .onHover { hoverCopy = $0 }
                
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
                    subtitle: searchText.isEmpty ? "Saved edits will appear here" : "No entries match your search"
                )
            } else {
                ScrollViewReader { proxy in
                    List(selection: $selectedEntry) {
                        ForEach(entries) { entry in
                            let isSelected = selectedEntry?.id == entry.id
                            HistoryEntryRow(entry: entry, meta: historyManager.meta(for: entry), isSelected: isSelected)
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
                                    Button("Copy to Clipboard") { copyAndClose(entry) }
                                    Button("Edit") { onSelectEntry(entry) }
                                    Divider()
                                    Button(entry.isPinned ? "Unpin" : "Pin") {
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
            TextField("Search history…", text: $searchText)
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
    
    private func syncSelectedEntry() {
        let entry = selectedEntry
        let callback = onSelectEntry
        AppDelegate.shared?.historyReturnAction = {
            if let entry = entry { callback(entry) }
        }
        AppDelegate.shared?.historyCopyAction = { [self] in
            if let entry = entry { copyAndClose(entry) }
        }
        AppDelegate.shared?.historyDeleteAction = { [self] in
            if let entry = entry { deleteEntry(entry) }
        }
        AppDelegate.shared?.historyFocusSearchAction = { [self] in
            searchFocused = true
        }
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
    }
}

// MARK: - Row

struct HistoryEntryRow: View {
    let entry: HistoryEntry
    let meta: HistoryEntryMeta
    var isSelected: Bool = false
    
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
