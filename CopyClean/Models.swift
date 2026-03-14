import SwiftUI
import Combine

struct HistoryEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let text: String
    let timestamp: Date
    var isPinned: Bool

    init(id: UUID = UUID(), text: String, timestamp: Date = Date(), isPinned: Bool = false) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.isPinned = isPinned
    }

    // Custom decoder for backwards compatibility – isPinned may be absent in old data
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id        = try container.decode(UUID.self,   forKey: .id)
        text      = try container.decode(String.self, forKey: .text)
        timestamp = try container.decode(Date.self,   forKey: .timestamp)
        isPinned  = (try container.decodeIfPresent(Bool.self, forKey: .isPinned)) ?? false
    }

    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: HistoryEntry, rhs: HistoryEntry) -> Bool {
        lhs.id == rhs.id
    }
}

class HistoryManager: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    private let saveKey = "CopyCleanHistory"

    init() {
        loadHistory()
    }

    func addEntry(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Deduplicate: skip if the most-recent entry has the same text
        if entries.first?.text == text { return }

        let entry = HistoryEntry(text: text)
        entries.insert(entry, at: 0)

        // Trim unpinned entries to the configured limit; pinned entries are kept regardless
        let max = SettingsManager.shared.maxHistory
        let pinned   = entries.filter {  $0.isPinned }
        var unpinned = entries.filter { !$0.isPinned }
        if unpinned.count > max {
            unpinned = Array(unpinned.prefix(max))
        }
        entries = pinned + unpinned

        saveHistory()
    }

    func deleteEntry(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        saveHistory()
    }

    func clearHistory() {
        entries.removeAll()
        saveHistory()
    }

    func togglePin(_ entry: HistoryEntry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx].isPinned.toggle()
            saveHistory()
        }
    }

    private func saveHistory() {
        if let encoded = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(encoded, forKey: saveKey)
        }
    }

    private func loadHistory() {
        if let data = UserDefaults.standard.data(forKey: saveKey),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = decoded
        }
    }
}

// ViewModel for editor state
class EditorViewModel: ObservableObject {
    @Published var text: String = ""
    var baseText: String = ""

    var isDirty: Bool { text != baseText }

    /// Load new text and mark it as the saved baseline.
    func load(_ newText: String) {
        text = newText
        baseText = newText
    }

    /// Mark the current text as saved.
    func markSaved() {
        baseText = text
    }
}

extension Notification.Name {
    static let clearHistory = Notification.Name("ClearHistory")
}
