import SwiftUI
import AppKit

private let appTeal    = Color(red: 0.165, green: 0.483, blue: 0.420)
private let appTealNS  = NSColor(red: 0.165, green: 0.483, blue: 0.420, alpha: 1.0)

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
        searchText.isEmpty
            ? historyManager.entries
            : historyManager.entries.filter { $0.text.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            detailPane
        }
        .frame(minWidth: 640, minHeight: 420)
        .onAppear {
            selectedEntry = filteredEntries.first
            syncSelectedEntry()
        }
        .onChange(of: selectedEntry) { syncSelectedEntry() }
        .onChange(of: historyManager.entries) {
            if let selected = selectedEntry,
               !historyManager.entries.contains(where: { $0.id == selected.id }) {
                selectedEntry = filteredEntries.first
            }
        }
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
                List(selection: $selectedEntry) {
                    ForEach(filteredEntries) { entry in
                        HistoryEntryRow(entry: entry, isSelected: selectedEntry?.id == entry.id)
                            .tag(entry)
                            .contextMenu {
                                Button("Copy to Clipboard") { copyAndClose(entry) }
                                Button("Edit") { onSelectEntry(entry) }
                                Divider()
                                Button("Delete", role: .destructive) { deleteEntry(entry) }
                            }
                    }
                    .onDelete { indexSet in
                        for index in indexSet { deleteEntry(filteredEntries[index]) }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(width: 260)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(appTeal)
                .imageScale(.small)
            TextField("Search history…", text: $searchText)
                .textFieldStyle(.plain)
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
            VStack(spacing: 0) {
                detailHeader(entry: entry)
                Divider()
                ScrollView {
                    Text(entry.text)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            }
        } else {
            emptyState(
                icon: "sidebar.left",
                title: "Select an Entry",
                subtitle: "Choose a clipboard entry from the list"
            )
        }
    }

    private func detailHeader(entry: HistoryEntry) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(formatRelativeDate(entry.timestamp))
                    .font(.headline)
                HStack(spacing: 8) {
                    statLabel("\(entry.text.components(separatedBy: "\n").count)", icon: "line.3.horizontal")
                    statLabel("\(entry.text.split { $0.isWhitespace || $0.isNewline }.count)", icon: "text.word.spacing")
                    statLabel("\(entry.text.count)", icon: "character")
                }
            }

            Spacer()

            Button(action: { deleteEntry(entry) }) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)

            Button("Copy") { copyAndClose(entry) }

            Button("Edit") { onSelectEntry(entry) }
                .buttonStyle(.borderedProminent)
                .tint(appTeal)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Helpers

    @ViewBuilder
    private func statLabel(_ value: String, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .foregroundColor(appTeal.opacity(0.7))
            Text(value)
                .monospacedDigit()
                .foregroundColor(.secondary)
        }
        .font(.caption)
    }

    @ViewBuilder
    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .thin))
                .foregroundColor(appTeal.opacity(0.5))
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
        if let first = lines.first { return String(first.prefix(60)) }
        return entry.text.prefix(60).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var secondLine: String? {
        let lines = entry.text.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > 1, let second = lines.dropFirst().first else { return nil }
        return String(second.prefix(60))
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
                Circle()
                    .fill(appTeal.opacity(isSelected ? 0.9 : 0.4))
                    .frame(width: 5, height: 5)
                Text(formatRelativeDate(entry.timestamp, style: .abbreviated))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
