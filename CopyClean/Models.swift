import SwiftUI
import Combine

// Model for history entries
struct HistoryEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let text: String
    let timestamp: Date
    
    init(id: UUID = UUID(), text: String, timestamp: Date = Date()) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
    }
    
    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: HistoryEntry, rhs: HistoryEntry) -> Bool {
        lhs.id == rhs.id
    }
}

// History manager to persist entries
class HistoryManager: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    private let saveKey = "CopyCleanHistory"
    private let maxEntries = 100
    
    init() {
        loadHistory()
    }
    
    func addEntry(_ text: String) {
        let entry = HistoryEntry(text: text)
        entries.insert(entry, at: 0)
        
        // Keep only the most recent entries
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        
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
}
