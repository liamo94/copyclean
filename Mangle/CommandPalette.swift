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
    let run: () -> Void

    var id: String { section + "/" + title }
}

/// Palette state lives in the editor so its key monitor can drive selection (↑/↓/↩/Esc)
/// while focus stays in the search field.
enum CommandPaletteResults {
    /// ":<n>" is a go-to-line request; everything else fuzzy-matches command titles.
    static func filter(_ commands: [EditorCommand], query: String, goToLine: @escaping (Int) -> Void) -> [EditorCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix(":") {
            let digits = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            if let line = Int(digits) {
                return [EditorCommand(title: "Go to Line \(line)", section: "Navigate", run: { goToLine(line) })]
            }
            return [EditorCommand(title: "Type a line number", section: "Navigate", isEnabled: false, run: {})]
        }
        let enabled = commands.filter(\.isEnabled)
        guard !trimmed.isEmpty else { return enabled }
        return enabled
            .compactMap { cmd -> (EditorCommand, Int)? in
                let titleScore = TextTransforms.fuzzyScore(trimmed, in: cmd.title)
                let sectionScore = TextTransforms.fuzzyScore(trimmed, in: cmd.section + " " + cmd.title).map { $0 / 2 }
                guard let score = [titleScore, sectionScore].compactMap({ $0 }).max() else { return nil }
                return (cmd, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }
}

struct CommandPaletteView: View {
    @Binding var query: String
    let results: [EditorCommand]
    let selectedIndex: Int
    let onRun: (EditorCommand) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command")
                    .foregroundColor(AppTheme.tealSUI)
                TextField("Type a command, or : and a line number", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
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
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, cmd in
                                // Identity comes from the command (ForEach's id). Also tagging rows
                                // with .id(index) made the lazy stack treat "row 0" as the same view
                                // whatever command it held, so filtered results and the selection
                                // highlight never redrew.
                                row(cmd, selected: index == selectedIndex)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onRun(cmd) }
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
        .onAppear { focused = true }
    }

    private func row(_ cmd: EditorCommand, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Text(cmd.title)
                .font(.system(size: 13))
                .foregroundColor(cmd.isEnabled ? (selected ? .white : .primary) : .secondary)
            Text(cmd.section)
                .font(.system(size: 11))
                .foregroundColor(selected ? .white.opacity(0.75) : .secondary)
            Spacer()
            if let shortcut = cmd.shortcut {
                Text(shortcut)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(selected ? .white.opacity(0.85) : .secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(selected ? AppTheme.tealSUI : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }
}
