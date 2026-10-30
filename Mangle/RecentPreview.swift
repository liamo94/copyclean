import AppKit
import Highlightr

/// The highlighted snippet beside the Copy Recent submenu, in place of a plain-text tooltip.
final class RecentPreviewPanel {
    private static let maxLines = 24
    private static let maxColumns = 100
    private static let maxWidth: CGFloat = 520

    private let panel: NSPanel
    private let label = NSTextField(labelWithAttributedString: NSAttributedString())
    private let footer = NSTextField(labelWithString: "")
    /// Made on first hover: it loads highlight.js into a fresh JSContext (~20ms). Separate from
    /// History's, whose theme and font that view tracks itself.
    private lazy var highlightr: Highlightr? = Highlightr()

    init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false

        let content = NSView()
        content.wantsLayer = true
        content.layer?.cornerRadius = 10
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 1
        content.layer?.borderColor = NSColor.separatorColor.cgColor
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byClipping
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        content.addSubview(label)
        content.addSubview(footer)
        panel.contentView = content
    }

    func show(_ entry: HistoryEntry, language: String, beside menuWindow: NSWindow?) {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let font = SettingsManager.shared.editorFont.nsFont(size: 12)

        let allLines = entry.text.split(separator: "\n", omittingEmptySubsequences: false)
        let shown = allLines.prefix(Self.maxLines).map { line in
            line.count > Self.maxColumns ? line.prefix(Self.maxColumns - 1) + "…" : line
        }
        let code = shown.joined(separator: "\n").trimmingCharacters(in: .newlines)

        var background = isDark ? AppTheme.editorDarkBG : NSColor.textBackgroundColor
        var attributed = NSAttributedString(string: code, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        if let h = highlightr {
            h.setTheme(to: SettingsManager.shared.themeName(isDark: isDark))
            h.theme.setCodeFont(font)
            if let bg = h.theme.themeBackgroundColor { background = bg }
            if let highlighted = h.highlight(code, as: language) { attributed = highlighted }
        }
        label.attributedStringValue = attributed

        let hidden = allLines.count - shown.count
        footer.stringValue = hidden > 0 ? "\(hidden) more line\(hidden == 1 ? "" : "s")…" : ""
        footer.isHidden = hidden <= 0

        // Size to the text, then lay out top-down in the unflipped content view.
        let inset: CGFloat = 12
        let textSize = label.sizeThatFits(NSSize(width: Self.maxWidth, height: .greatestFiniteMagnitude))
        let textWidth = min(ceil(textSize.width), Self.maxWidth)
        let footerHeight: CGFloat = footer.isHidden ? 0 : ceil(footer.intrinsicContentSize.height) + 6
        let size = NSSize(width: max(textWidth, footer.isHidden ? 0 : footer.intrinsicContentSize.width) + inset * 2,
                          height: ceil(textSize.height) + footerHeight + inset * 2)
        label.frame = NSRect(x: inset, y: inset + footerHeight, width: textWidth, height: ceil(textSize.height))
        footer.frame = NSRect(x: inset, y: inset, width: size.width - inset * 2, height: footerHeight - 6)
        panel.contentView?.layer?.backgroundColor = background.cgColor

        panel.setFrame(NSRect(origin: origin(for: size, beside: menuWindow), size: size), display: true)
        panel.orderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    /// Level with the submenu's top, on whichever side doesn't cover the menu it came from.
    private func origin(for size: NSSize, beside menuWindow: NSWindow?) -> NSPoint {
        let gap: CGFloat = 6
        guard let menu = menuWindow?.frame else {
            let mouse = NSEvent.mouseLocation
            return NSPoint(x: mouse.x + 16, y: mouse.y - size.height - 16)
        }
        let screen = (menuWindow?.screen ?? NSScreen.main)?.visibleFrame ?? menu
        let parent = RecentPreviewPanel.menuWindows().first { $0.frame != menu }?.frame
        let preferLeft = parent.map { $0.midX > menu.midX } ?? false
        let leftX = menu.minX - gap - size.width
        let rightX = menu.maxX + gap
        var x = preferLeft ? leftX : rightX
        if x < screen.minX || x + size.width > screen.maxX { x = preferLeft ? rightX : leftX }
        x = min(max(x, screen.minX), screen.maxX - size.width)
        let y = max(menu.maxY - size.height, screen.minY)
        return NSPoint(x: x, y: y)
    }

    /// The windows AppKit draws open menus in.
    static func menuWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.isVisible && $0.level.rawValue >= NSWindow.Level.popUpMenu.rawValue
            && String(describing: type(of: $0)).contains("Menu") }
    }
}
