import SwiftUI
import AppKit
import Highlightr


private func formatRelativeDate(_ date: Date, style: RelativeDateTimeFormatter.UnitsStyle = .full) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = style
    return formatter.localizedString(for: date, relativeTo: Date())
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
    
    private var filteredEntries: [HistoryEntry] {
        let base = searchText.isEmpty
        ? historyManager.entries
        : historyManager.entries.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
        // Pinned entries always shown first
        return base.sorted { ($0.isPinned ? 0 : 1) < ($1.isPinned ? 0 : 1) }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
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
                HStack(spacing: 10) {
                    Text(formatRelativeDate(entry.timestamp, style: .abbreviated))
                        .foregroundColor(.secondary)
                        .font(.system(size: 12))
                    
                    barDivider
                    
                    statPill("\(entry.text.components(separatedBy: "\n").count)", label: "lines")
                    statPill("\(entry.text.split { $0.isWhitespace || $0.isNewline }.count)", label: "words")
                    statPill("\(entry.text.count)", label: "chars")
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
    
    private var sidebar: some View {
        VStack(spacing: 0) {
            searchBar
            
            Divider()
            
            if filteredEntries.isEmpty {
                emptyState(
                    icon: searchText.isEmpty ? "doc.text" : "magnifyingglass",
                    title: searchText.isEmpty ? "No History" : "No Results",
                    subtitle: searchText.isEmpty ? "Saved edits will appear here" : "No entries match your search"
                )
            } else {
                ScrollViewReader { proxy in
                    List(selection: $selectedEntry) {
                        ForEach(filteredEntries) { entry in
                            let isSelected = selectedEntry?.id == entry.id
                            HistoryEntryRow(entry: entry, isSelected: isSelected)
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
                                let entry = filteredEntries[index]
                                deleteEntry(entry)
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
            let lang = entry.language ?? CustomTextEditor.Coordinator.guessLanguage(entry.text)
            SyntaxPreviewView(text: entry.text, language: lang)
                .id(entry.id)
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
    var isSelected: Bool = false
    
    private var preview: String {
        let lines = entry.text.split(separator: "\n", omittingEmptySubsequences: true)
        if let first = lines.first { return String(first.drop(while: { $0 == " " || $0 == "\t" }).prefix(60)) }
        return entry.text.prefix(60).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private var secondLine: String? {
        let lines = entry.text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > 1, let second = lines.dropFirst().first else { return nil }
        return String(second.drop(while: { $0 == " " || $0 == "\t" }).prefix(60))
    }
    
    private var detectedLanguage: String {
        entry.language ?? CustomTextEditor.Coordinator.guessLanguage(entry.text)
    }
    
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
                Circle()
                    .fill(AppTheme.tealSUI.opacity(isSelected ? 0.9 : 0.4))
                    .frame(width: 5, height: 5)
                Text(formatRelativeDate(entry.timestamp, style: .abbreviated))
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
    let text: String
    let language: String
    
    class Coordinator {
        var highlightr: Highlightr?
        var codeStorage: CodeAttributedString?
        
        init() {
            guard let h = Highlightr() else { return }
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            h.setTheme(to: isDark ? "atom-one-dark" : "xcode")
            h.theme.setCodeFont(.monospacedSystemFont(ofSize: 12, weight: .regular))
            self.highlightr = h
            self.codeStorage = CodeAttributedString(highlightr: h)
        }
    }
    
    func makeCoordinator() -> Coordinator { Coordinator() }
    
    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let textStorage = coordinator.codeStorage ?? NSTextStorage()
        
        let layoutManager = NSLayoutManager()
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
        
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDark, let bg = coordinator.highlightr?.theme.themeBackgroundColor {
            textView.backgroundColor = bg
        }
        
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        if isDark, let bg = coordinator.highlightr?.theme.themeBackgroundColor {
            scrollView.backgroundColor = bg
        }
        
        return scrollView
    }
    
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let storage = context.coordinator.codeStorage else {
            (scrollView.documentView as? NSTextView)?.string = text
            return
        }
        let lang = language == "plaintext" ? "plaintext" : language
        if storage.language != lang { storage.language = lang }
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        scrollView.documentView?.scroll(.zero)
    }
}
