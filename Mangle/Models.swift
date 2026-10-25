import SwiftUI
import AppKit
import Combine

struct HistoryEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let text: String
    var timestamp: Date
    var isPinned: Bool
    var language: String? // nil = auto-detect; set when user manually picks a language
    /// Saved from a scratch pad rather than copied.
    var isScratch: Bool

    init(id: UUID = UUID(), text: String, timestamp: Date = Date(), isPinned: Bool = false, language: String? = nil, isScratch: Bool = false) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.isPinned = isPinned
        self.language = language
        self.isScratch = isScratch
    }

    // Custom decoder for backwards compatibility – isPinned/language/isScratch may be absent in old data
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id        = try container.decode(UUID.self,   forKey: .id)
        text      = try container.decode(String.self, forKey: .text)
        timestamp = try container.decode(Date.self,   forKey: .timestamp)
        isPinned  = (try container.decodeIfPresent(Bool.self,   forKey: .isPinned)) ?? false
        language  =  try container.decodeIfPresent(String.self, forKey: .language)
        isScratch = (try container.decodeIfPresent(Bool.self,   forKey: .isScratch)) ?? false
    }

    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: HistoryEntry, rhs: HistoryEntry) -> Bool {
        lhs.id == rhs.id
    }
}

/// Derived, display-only data for a history entry. `text` is immutable, so this is
/// computed once per entry instead of re-splitting/re-hashing the full text on every render.
struct HistoryEntryMeta {
    let preview: String
    let secondLine: String?
    let detectedLanguage: String
    let lines: Int
    let words: Int
    let chars: Int
}

class HistoryManager: ObservableObject {
    @Published var entries: [HistoryEntry] = []
    private let legacySaveKey = "MangleHistory"
    private var metaCache: [UUID: HistoryEntryMeta] = [:]
    private let saveQueue = DispatchQueue(label: "co.liamo.mangle.history-save", qos: .utility)
    private var pendingSave: DispatchWorkItem?

    nonisolated private static var historyFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Mangle", isDirectory: true).appendingPathComponent("history.json")
    }

    init() {
        loadHistory()
    }

    func meta(for entry: HistoryEntry) -> HistoryEntryMeta {
        if let cached = metaCache[entry.id] { return cached }
        let text = entry.text
        let nonEmptyLines = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: true)
        let trimLeading: (Substring) -> String = { String($0.drop(while: { $0 == " " || $0 == "\t" }).prefix(60)) }
        let preview = nonEmptyLines.first.map(trimLeading)
            ?? text.prefix(60).trimmingCharacters(in: .whitespacesAndNewlines)
        let secondLine = nonEmptyLines.count > 1 ? trimLeading(nonEmptyLines[1]) : nil
        let stats = TextStats.compute(text)
        let meta = HistoryEntryMeta(
            preview: preview,
            secondLine: secondLine,
            detectedLanguage: CustomTextEditor.Coordinator.guessLanguage(text),
            lines: stats.lines, words: stats.words, chars: stats.chars
        )
        metaCache[entry.id] = meta
        return meta
    }

    func addEntry(_ text: String, isScratch: Bool = false) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        // Deduplicate against the whole list, not just the most recent entry — copying
        // A, then B, then A again used to leave two separate "A" entries in history.
        if let idx = entries.firstIndex(where: { $0.text == text }) {
            entries[idx].timestamp = Date()
            if idx != 0 {
                let existing = entries.remove(at: idx)
                entries.insert(existing, at: 0)
            }
            saveHistory()
            return
        }

        let entry = HistoryEntry(text: text, isScratch: isScratch)
        entries.insert(entry, at: 0)
        enforceLimit()
        saveHistory()
    }

    /// Trim unpinned entries to the configured limit; pinned entries are kept regardless.
    /// Order is preserved (pinned entries aren't hoisted — the UI sorts them for display).
    func enforceLimit(save: Bool = false) {
        let max = SettingsManager.shared.maxHistory
        var unpinnedSeen = 0
        let trimmed = entries.filter { entry in
            if entry.isPinned { return true }
            unpinnedSeen += 1
            return unpinnedSeen <= max
        }
        guard trimmed.count != entries.count else { return }
        let kept = Set(trimmed.map(\.id))
        for id in metaCache.keys where !kept.contains(id) { metaCache[id] = nil }
        entries = trimmed
        if save { saveHistory() }
    }

    func deleteEntry(_ entry: HistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        metaCache[entry.id] = nil
        saveHistory()
    }

    func clearHistory() {
        entries.removeAll()
        metaCache.removeAll()
        saveHistory()
    }

    func togglePin(_ entry: HistoryEntry) {
        if let idx = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[idx].isPinned.toggle()
            saveHistory()
        }
    }

    func updateLanguage(for id: UUID, language: String) {
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx].language = language
            saveHistory()
        }
    }

    /// Encodes and writes off the main thread, coalescing bursts of changes into one write.
    /// History used to live in UserDefaults, which rewrote the whole (potentially multi-MB)
    /// plist synchronously on every change.
    private func saveHistory() {
        let snapshot = entries
        pendingSave?.cancel()
        let work = DispatchWorkItem { Self.write(snapshot) }
        pendingSave = work
        saveQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Flush any pending write immediately (used at app termination).
    func flush() {
        guard let work = pendingSave else { return }
        work.cancel()
        pendingSave = nil
        let snapshot = entries
        saveQueue.sync { _ = Self.write(snapshot) }
    }
    
    @discardableResult
    nonisolated private static func write(_ entries: [HistoryEntry]) -> Bool {
        guard let data = try? JSONEncoder().encode(entries) else { return false }
        let url = historyFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    private func loadHistory() {
        if let data = try? Data(contentsOf: Self.historyFileURL),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = decoded
            return
        }
        // One-time migration from the old UserDefaults storage
        if let data = UserDefaults.standard.data(forKey: legacySaveKey),
           let decoded = try? JSONDecoder().decode([HistoryEntry].self, from: data) {
            entries = decoded
            // Write synchronously and only drop the old copy once the file definitely exists.
            if Self.write(decoded) {
                UserDefaults.standard.removeObject(forKey: legacySaveKey)
            }
        }
    }
}

// MARK: - Text Stats

nonisolated enum TextStats {
    /// Lines / words / characters in one pass over UTF-16 (words) plus a grapheme count.
    static func compute(_ text: String) -> (lines: Int, words: Int, chars: Int) {
        guard !text.isEmpty else { return (1, 0, 0) }
        var lines = 1
        var words = 0
        var inWord = false
        for unit in text.utf16 {
            let isSpace = unit == 32 || unit == 9 || unit == 10 || unit == 13 || unit == 0xA0 || unit == 0x2028 || unit == 0x2029
            if unit == 10 { lines += 1 }
            if isSpace {
                inWord = false
            } else if !inWord {
                inWord = true
                words += 1
            }
        }
        return (lines, words, text.count)
    }
}

/// Live status-bar values. Kept out of `EditorViewModel`'s published state so that cursor
/// moves and stat updates only re-render the small views that display them, not the whole editor.
final class EditorStatus: ObservableObject {
    @Published var cursorLine = 1
    @Published var cursorColumn = 1
    @Published var lines = 1
    @Published var words = 0
    @Published var chars = 0
    @Published var indentation: Indentation = .spaces(4)
    @Published var lineEnding: LineEnding = .lf
}

// ViewModel for editor state
class EditorViewModel: ObservableObject {
    /// The text view is the source of truth while editing — typing doesn't round-trip
    /// through SwiftUI. `loadedText` is only what was last pushed *into* the editor.
    private(set) var loadedText: String = ""
    /// Bumped whenever new text is pushed into the editor; `CustomTextEditor` applies it then.
    @Published private(set) var loadGeneration = 0
    @Published var currentLanguage: String = "plaintext"
    var baseText: String = ""
    var languageIsManual: Bool = false  // true when user explicitly picked a language
    var sourceEntryID: UUID? = nil      // set when editing an existing history entry
    /// A blank scratch pad rather than an edit of copied text: closing it doesn't ask to
    /// discard, and its text is kept in history when something replaces it.
    @Published private(set) var isScratch = false
    /// Large text, minimal chrome, and the window stays up when the app loses focus.
    @Published var isPresenting = false
    let status = EditorStatus()
    weak var textView: NSTextView?

    /// The current editor contents.
    var text: String { textView?.string ?? loadedText }

    var isDirty: Bool { text != baseText }

    /// Load new text and mark it as the saved baseline. Passing a language marks it as a
    /// manual choice; otherwise it's detected here, up front, so the editor highlights once
    /// with the right grammar instead of flashing the previous document's language first.
    func load(_ newText: String, language: String? = nil) {
        loadedText = newText
        baseText = newText
        if let language {
            languageIsManual = true
            currentLanguage = language
        } else {
            languageIsManual = false
            // Highlighting multi-MB documents costs seconds of CPU and a main-thread hitch
            // applying the attributes; default those to plain text (users can still pick one).
            currentLanguage = newText.utf16.count > 1_000_000
                ? "plaintext"
                : CustomTextEditor.Coordinator.guessLanguage(newText)
        }
        isScratch = false
        loadGeneration += 1
    }
    
    /// Starts an empty scratch pad.
    func loadScratch() {
        load("")
        sourceEntryID = nil
        isScratch = true
    }

    /// Mark the current text as saved.
    func markSaved() {
        baseText = text
    }
    
    /// Throws away the current text so a hidden editor (or saved draft) can't bring it back.
    func discard() {
        load("")
        sourceEntryID = nil
        EditorDraft.clear()
    }
    
    /// Reloads a draft from a previous run, keeping it marked as unsaved.
    func restore(_ draft: EditorDraft) {
        load(draft.text, language: draft.languageIsManual ? draft.language : nil)
        baseText = draft.baseText
        sourceEntryID = draft.sourceEntryID
        isScratch = draft.isScratch ?? false
    }
}

/// Unsaved editor contents persisted across app launches.
struct EditorDraft: Codable {
    let text: String
    let baseText: String
    let language: String
    let languageIsManual: Bool
    let sourceEntryID: UUID?
    let clipboardChangeCount: Int
    let isScratch: Bool?
    
    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mangle", isDirectory: true)
            .appendingPathComponent("draft.json")
    }
    
    static func load() -> EditorDraft? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EditorDraft.self, from: data)
    }
    
    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.url, options: .atomic)
    }
    
    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

extension Notification.Name {
    static let clearHistory = Notification.Name("ClearHistory")
}
