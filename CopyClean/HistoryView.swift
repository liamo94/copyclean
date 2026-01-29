import SwiftUI
import AppKit

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
    
    private var filteredEntries: [HistoryEntry] {
        if searchText.isEmpty {
            return historyManager.entries
        }
        return historyManager.entries.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        HStack(spacing: 0) {
            // Left sidebar - list of entries
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(Color(nsColor: .controlBackgroundColor))
                
                Divider()
                
                // Entry list
                if filteredEntries.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("No History")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text(searchText.isEmpty ? "Saved edits will appear here" : "No matching entries")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: $selectedEntry) {
                        ForEach(filteredEntries) { entry in
                            HistoryEntryRow(entry: entry)
                                .tag(entry)
                                .contextMenu {
                                    Button("Copy to Clipboard") {
                                        copyAndClose(entry)
                                    }
                                    Button("Edit") {
                                        onSelectEntry(entry)
                                    }
                                    Divider()
                                    Button("Delete", role: .destructive) {
                                        deleteEntry(entry)
                                    }
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
                }
            }
            .frame(width: 250)
            
            Divider()
            
            // Right side - preview/editor
            VStack {
                if let entry = selectedEntry {
                    VStack(spacing: 0) {
                        // Header with timestamp
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(formatRelativeDate(entry.timestamp))
                                    .font(.headline)
                                Text("\(entry.text.count) characters")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Button("Edit") {
                                onSelectEntry(entry)
                            }
                            .buttonStyle(.borderedProminent)
                            
                            Button("Copy") {
                                copyAndClose(entry)
                            }
                            
                            Button(action: {
                                deleteEntry(entry)
                            }) {
                                Image(systemName: "trash")
                            }
                            .foregroundColor(.red)
                        }
                        .padding()
                        .background(Color(nsColor: .controlBackgroundColor))
                        
                        Divider()
                        
                        // Text preview
                        ScrollView {
                            Text(entry.text)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "arrow.left")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("Select an Entry")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("Choose an entry from the list to view")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .onAppear {
            selectedEntry = filteredEntries.first
            syncSelectedEntry()
        }
        .onChange(of: selectedEntry) {
            syncSelectedEntry()
        }
        .onChange(of: historyManager.entries) {
            if let selected = selectedEntry,
               !historyManager.entries.contains(where: { $0.id == selected.id }) {
                selectedEntry = filteredEntries.first
            }
        }
    }
    
    private func copyAndClose(_ entry: HistoryEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(entry.text, forType: .string)
        onClose()
    }
    
    private func syncSelectedEntry() {
        let entry = selectedEntry
        let callback = onSelectEntry
        AppDelegate.shared?.historyReturnAction = {
            if let entry = entry {
                callback(entry)
            }
        }
        AppDelegate.shared?.historyCopyAction = { [self] in
            if let entry = entry {
                copyAndClose(entry)
            }
        }
        AppDelegate.shared?.historyDeleteAction = { [self] in
            if let entry = entry {
                deleteEntry(entry)
            }
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


// Row view for history entries
struct HistoryEntryRow: View {
    let entry: HistoryEntry
    
    private var preview: String {
        let lines = entry.text.split(separator: "\n", omittingEmptySubsequences: true)
        if let firstLine = lines.first {
            return String(firstLine.prefix(50))
        }
        return entry.text.prefix(50).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private var secondLine: String? {
        let lines = entry.text.split(separator: "\n", omittingEmptySubsequences: true)
        if lines.count > 1, let second = lines.dropFirst().first {
            return String(second.prefix(50))
        }
        return nil
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(preview)
                .font(.system(.body))
                .lineLimit(1)
            
            if let second = secondLine {
                Text(second)
                    .font(.system(.caption))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            
            Text(formatRelativeDate(entry.timestamp, style: .abbreviated))
                .font(.system(.caption2))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 4)
    }
}
