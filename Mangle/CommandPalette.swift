import SwiftUI

/// One action available from the Transform menu and/or the command palette.
struct EditorCommand: Identifiable {
    let title: String
    let section: String
    /// Display string for the shortcut (e.g. "⌘⇧T"), shown in menus and the palette.
    var shortcut: String? = nil
    /// Shortcut to bind on the menu item; only set where the menu is the shortcut's owner.
    var keyboardShortcut: SwiftUI.KeyboardShortcut? = nil
    var isEnabled: Bool = true
    /// Shows a checkmark in the palette (the active language, indentation, line ending…).
    var isCurrent: Bool = false
    /// Shown in place of the section, e.g. why a command is unavailable or a line preview.
    var detail: String? = nil
    /// Stable identity for commands whose title changes with state ("Turn On/Off Word Wrap"),
    /// so they keep their place in the recent list.
    var key: String? = nil
    let run: () -> Void

    var id: String { key ?? section + "/" + title }
}

/// A palette row: the command plus what the query matched in its title.
struct CommandPaletteResult: Identifiable {
    let command: EditorCommand
    /// Character offsets in `command.title` matched by the query.
    var matches: [Int] = []
    var isRecent = false

    var id: String { command.id }
}

/// Palette state lives in the editor so its key monitor can drive selection (↑/↓/↩/Esc)
/// while focus stays in the search field.
enum CommandPaletteResults {
    private static let recentKey = "MangleRecentPaletteCommands"
    private static let recentLimit = 5

    /// Most recent first.
    static var recentIDs: [String] {
        UserDefaults.standard.stringArray(forKey: recentKey) ?? []
    }

    static func recordRecent(_ id: String) {
        var ids = recentIDs.filter { $0 != id }
        ids.insert(id, at: 0)
        UserDefaults.standard.set(Array(ids.prefix(recentLimit)), forKey: recentKey)
    }

    /// ":<line>[:<column>]" (or a bare number) is a go-to-line request; everything else
    /// fuzzy-matches command titles. Disabled commands only appear when searched for, after
    /// the enabled ones, so it's clear why they can't run.
    static func filter(_ commands: [EditorCommand], query: String, recent: [String] = recentIDs,
                       document: NSString, goToLine: @escaping (Int, Int?) -> Void) -> [CommandPaletteResult] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(":") {
            return [goToLineResult(String(trimmed.dropFirst()), document: document, goToLine: goToLine)]
        }
        let recentRank = Dictionary(recent.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })

        guard !trimmed.isEmpty else {
            let enabled = commands.filter(\.isEnabled)
            let recentCommands = enabled
                .filter { recentRank[$0.id] != nil }
                .sorted { recentRank[$0.id]! < recentRank[$1.id]! }
                .map { CommandPaletteResult(command: $0, isRecent: true) }
            let rest = enabled
                .filter { recentRank[$0.id] == nil }
                .map { CommandPaletteResult(command: $0) }
            return recentCommands + rest
        }

        let scored = commands.enumerated().compactMap { index, cmd -> (CommandPaletteResult, score: Int, index: Int)? in
            let title = TextTransforms.fuzzyMatch(trimmed, in: cmd.title)
            // Matching across "section title" lets "json min" find Minify JSON; its positions
            // are shifted back onto the title, dropping any that landed in the section.
            let offset = cmd.section.count + 1
            let section = TextTransforms.fuzzyMatch(trimmed, in: cmd.section + " " + cmd.title)
                .map { (score: $0.score / 2, positions: $0.positions.filter { $0 >= offset }.map { $0 - offset }) }
            guard let best = [title, section].compactMap({ $0 }).max(by: { $0.score < $1.score }) else { return nil }
            return (CommandPaletteResult(command: cmd, matches: best.positions, isRecent: recentRank[cmd.id] != nil),
                    best.score, index)
        }
        // Enabled first, then score; ties go to recently used, then definition order
        // (Swift's sort isn't guaranteed stable).
        let matches = scored.sorted { a, b in
            if a.0.command.isEnabled != b.0.command.isEnabled { return a.0.command.isEnabled }
            if a.score != b.score { return a.score > b.score }
            let ra = recentRank[a.0.id] ?? .max, rb = recentRank[b.0.id] ?? .max
            if ra != rb { return ra < rb }
            return a.index < b.index
        }.map(\.0)

        // A bare number offers Go to Line first, ahead of commands like "Collapse to Depth 2".
        if trimmed.allSatisfy(\.isNumber) {
            return [goToLineResult(trimmed, document: document, goToLine: goToLine)] + matches
        }
        return matches
    }

    private static func goToLineResult(_ spec: String, document: NSString,
                                       goToLine: @escaping (Int, Int?) -> Void) -> CommandPaletteResult {
        func row(_ title: String, enabled: Bool = true, detail: String? = nil, run: @escaping () -> Void = {}) -> CommandPaletteResult {
            CommandPaletteResult(command: EditorCommand(title: title, section: "Navigate", isEnabled: enabled, detail: detail, run: run))
        }
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count <= 2, let requested = Int(parts[0]) else {
            return row("Type a line number", enabled: false, detail: "e.g. :42 or :42:8")
        }
        let column = parts.count == 2 && !parts[1].isEmpty ? Int(parts[1]) : nil
        if parts.count == 2, !parts[1].isEmpty, column == nil {
            return row("Type a column number", enabled: false, detail: "e.g. :42:8")
        }
        guard requested >= 1, (column ?? 1) >= 1 else {
            return row("Line and column numbers start at 1", enabled: false)
        }

        let lines = lineInfo(document, upTo: requested)
        let line = min(requested, lines.count)
        var title = "Go to Line \(line)"
        if let column { title += ", Column \(column)" }
        if line < requested { title += " (last line)" }
        let preview = lines.target.trimmingCharacters(in: .whitespaces)
        return row(title, detail: preview.isEmpty ? "\(lines.count) lines" : String(preview.prefix(60))) {
            goToLine(line, column)
        }
    }

    /// The total line count (as the editor numbers them) and the text of `line`, or of the
    /// last line when the document is shorter.
    private static func lineInfo(_ ns: NSString, upTo line: Int) -> (count: Int, target: String) {
        var count = 0
        var target = ""
        var location = 0
        repeat {
            let range = ns.lineRange(for: NSRange(location: location, length: 0))
            count += 1
            if count <= line {
                var contentsEnd = 0
                ns.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: range)
                target = ns.substring(with: NSRange(location: range.location, length: contentsEnd - range.location))
            }
            location = NSMaxRange(range)
        } while location < ns.length
        // A trailing line break starts one more (empty) line.
        if ns.length > 0, [10, 13].contains(ns.character(at: ns.length - 1)) {
            count += 1
            if count <= line { target = "" }
        }
        return (count, target)
    }
}

struct CommandPaletteView: View {
    @Binding var query: String
    let results: [CommandPaletteResult]
    let selectedIndex: Int
    let onSelect: (Int) -> Void
    let onRun: (EditorCommand) -> Void
    @FocusState private var focused: Bool
    /// Hover only moves the selection when the mouse itself moves — not when keyboard
    /// navigation scrolls a row under a resting pointer.
    @State private var lastMouseLocation: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundColor(AppTheme.tealSUI)
                    .accessibilityHidden(true)
                TextField("Type a command, or : and a line number", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .accessibilityLabel("Command palette")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            if results.isEmpty {
                Text("No matching commands")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, result in
                                // Identity comes from the command (ForEach's id). Also tagging rows
                                // with .id(index) made the lazy stack treat "row 0" as the same view
                                // whatever command it held, so filtered results and the selection
                                // highlight never redrew.
                                Button { onRun(result.command) } label: {
                                    row(result, selected: index == selectedIndex)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(!result.command.isEnabled)
                                .onHover { inside in
                                    let location = NSEvent.mouseLocation
                                    guard inside, location != lastMouseLocation else { return }
                                    lastMouseLocation = location
                                    onSelect(index)
                                }
                                .accessibilityLabel(accessibilityLabel(for: result.command))
                                .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
                            }
                        }
                        .padding(4)
                    }
                    .frame(maxHeight: 300)
                    .onChange(of: selectedIndex) { _, index in
                        if results.indices.contains(index) { proxy.scrollTo(results[index].id) }
                    }
                }
            }
        }
        .frame(width: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.25)))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
        .onAppear {
            focused = true
            lastMouseLocation = NSEvent.mouseLocation
        }
    }

    private func row(_ result: CommandPaletteResult, selected: Bool) -> some View {
        let cmd = result.command
        let secondary = selected ? AppTheme.onTealSUI.opacity(0.6) : Color.secondary
        return HStack(spacing: 8) {
            Image(systemName: "clock")
                .font(.system(size: 10))
                .foregroundColor(secondary)
                .frame(width: 12)
                .opacity(result.isRecent ? 1 : 0)
                .accessibilityHidden(true)
            Text(highlightedTitle(result, selected: selected))
                .font(.system(size: 13))
                .foregroundColor(cmd.isEnabled ? (selected ? AppTheme.onTealSUI.opacity(0.88) : .primary) : (selected ? AppTheme.onTealSUI.opacity(0.45) : .secondary))
                .lineLimit(1)
                .layoutPriority(1)
            Text(cmd.detail ?? cmd.section)
                .font(cmd.section == "Navigate" && cmd.detail != nil ? .system(size: 11, design: .monospaced) : .system(size: 11))
                .foregroundColor(secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
            if cmd.isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(selected ? AppTheme.onTealSUI.opacity(0.7) : AppTheme.tealSUI)
            }
            if let shortcut = cmd.shortcut {
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(selected ? AppTheme.onTealSUI.opacity(0.7) : .secondary)
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(selected ? AppTheme.tealSUI : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }

    /// The title with the query's matched letters in bold (and teal, off the selection).
    private func highlightedTitle(_ result: CommandPaletteResult, selected: Bool) -> AttributedString {
        guard !result.matches.isEmpty else { return AttributedString(result.command.title) }
        let matched = Set(result.matches)
        var text = AttributedString()
        for (offset, character) in result.command.title.enumerated() {
            var piece = AttributedString(String(character))
            if matched.contains(offset) {
                piece.font = .system(size: 13, weight: .bold)
                if !selected && result.command.isEnabled { piece.foregroundColor = AppTheme.tealSUI }
            }
            text += piece
        }
        return text
    }

    private func accessibilityLabel(for cmd: EditorCommand) -> String {
        var parts = [cmd.title, cmd.detail ?? cmd.section]
        if cmd.isCurrent { parts.append("current") }
        if let shortcut = cmd.shortcut { parts.append(shortcut) }
        if !cmd.isEnabled { parts.append("unavailable") }
        return parts.joined(separator: ", ")
    }
}
