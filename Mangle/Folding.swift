import AppKit

// MARK: - Code Folding
//
// Folded text stays in the document; only its glyphs are hidden. The layout manager delegate
// marks hidden characters as null glyphs (newlines and tabs as zero-advance control characters,
// so the lines merge) and turns the first hidden character into a fixed-width blank, which
// `drawFoldPlaceholders` paints as a ⋯ pill.

extension MangleTextView: NSLayoutManagerDelegate {

    static func outermostFolds(_ folds: [NSRange]) -> [NSRange] {
        let sorted = folds.sorted { $0.location != $1.location ? $0.location < $1.location : $0.length > $1.length }
        var result: [NSRange] = []
        for f in sorted where result.last.map({ f.location >= NSMaxRange($0) }) ?? true { result.append(f) }
        return result
    }

    /// Foldable blocks, recomputed lazily after edits. `byLine` maps a line to the first
    /// (outermost) block that opens on it. With `allowingStale` (the gutter, which redraws
    /// per keystroke), large documents get the previous result and a rescan once typing pauses.
    func foldRegions(allowingStale: Bool = false) -> (regions: [FoldRegion], byLine: [Int: Int]) {
        if let cache = regionCache, cache.version == textVersion { return (cache.regions, cache.byLine) }
        if allowingStale, let cache = regionCache, (string as NSString).length > Self.syncFoldScanLimit {
            scheduleFoldRescan()
            return (cache.regions, cache.byLine)
        }
        let regions = FoldScanner.regions(in: string as NSString, skipStrings: foldSkipsStrings)
        var byLine: [Int: Int] = [:]
        for (i, r) in regions.enumerated() where byLine[r.line] == nil { byLine[r.line] = i }
        regionCache = (textVersion, regions, byLine)
        return (regions, byLine)
    }

    /// Documents up to this size are rescanned synchronously (well under a millisecond).
    private static let syncFoldScanLimit = 200_000
    
    private func scheduleFoldRescan() {
        foldRescanWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            _ = self.foldRegions()
            self.enclosingScrollView?.verticalRulerView?.needsDisplay = true
        }
        foldRescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
    
    func isFolded(_ region: FoldRegion) -> Bool { folds.contains(region.foldRange) }

    /// The last visible fold starting at or before `location` (binary search).
    private func visibleFold(atOrBefore location: Int) -> NSRange? {
        var lo = 0, hi = visibleFolds.count - 1
        var found: NSRange?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if visibleFolds[mid].location <= location { found = visibleFolds[mid]; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }

    /// The fold at `location`'s placeholder, if `location` is exactly there.
    func fold(startingAt location: Int) -> NSRange? {
        guard let f = visibleFold(atOrBefore: location), f.location == location else { return nil }
        return f
    }

    /// The fold ending at `location` (the caret just before its closing bracket).
    func fold(endingAt location: Int) -> NSRange? {
        guard let f = visibleFold(atOrBefore: location), NSMaxRange(f) == location else { return nil }
        return f
    }

    private enum FoldState { case visible, placeholder, hidden }

    private func foldState(at location: Int) -> FoldState {
        guard let f = visibleFold(atOrBefore: location), location < NSMaxRange(f) else { return .visible }
        return location == f.location ? .placeholder : .hidden
    }

    /// When `lineStart` begins a line merged into a folded line above, the fold doing it.
    func fold(hidingLineStart lineStart: Int) -> NSRange? {
        guard lineStart > 0, let f = visibleFold(atOrBefore: lineStart - 1), lineStart <= NSMaxRange(f) else { return nil }
        return f
    }

    func setFolds(_ newFolds: [NSRange]) {
        let length = (string as NSString).length
        var seen = Set<Int>()
        let valid = newFolds.filter { $0.length > 0 && NSMaxRange($0) < length && seen.insert($0.location).inserted }
        guard Set(valid.map { NSValue(range: $0) }) != Set(folds.map { NSValue(range: $0) }) else { return }
        let affected = Self.outermostFolds(folds + valid)
        folds = valid
        for r in affected { invalidateFoldDisplay(r) }
        moveSelectionOutOfFolds()
    }

    func fold(_ range: NSRange) {
        guard !folds.contains(range) else { return }
        setFolds(folds + [range])
    }

    func unfold(_ range: NSRange) {
        guard folds.contains(range) else { return }
        setFolds(folds.filter { $0 != range })
    }

    func unfoldAll() { setFolds([]) }

    /// Folds the block opening on `line`, or unfolds it if it's folded.
    @discardableResult
    func toggleFold(onLine line: Int) -> Bool {
        let (regions, byLine) = foldRegions()
        guard let index = byLine[line] else { return false }
        let range = regions[index].foldRange
        if folds.contains(range) { unfold(range) } else { fold(range) }
        return true
    }

    /// Folds the block opening on the caret's line, else the innermost block around the caret.
    func foldAtCaret() {
        let caret = selectedRange().location
        let (regions, byLine) = foldRegions()
        let onLine = byLine[lineNumber(at: caret)].map { regions[$0] }.flatMap { isFolded($0) ? nil : $0 }
        guard let target = onLine
                ?? regions.last(where: { $0.opener < caret && caret <= $0.closer && !isFolded($0) }) else {
            NSSound.beep()
            return
        }
        fold(target.foldRange)   // moves the caret out only if it was inside the folded text
    }

    /// Unfolds the block on the caret's line, else the innermost fold around the caret.
    func unfoldAtCaret() {
        let caret = selectedRange().location
        let (regions, byLine) = foldRegions()
        if let index = byLine[lineNumber(at: caret)], isFolded(regions[index]) {
            unfold(regions[index].foldRange)
        } else if let f = folds.filter({ $0.location - 1 <= caret && caret <= NSMaxRange($0) }).max(by: { $0.location < $1.location }) {
            unfold(f)
        } else {
            NSSound.beep()
        }
    }

    /// Fold level of each block: 1 for top-level blocks. A single block wrapping the whole
    /// document (a JSON root) is level 0, so its contents count as the top level.
    private func foldLevels() -> [(region: FoldRegion, level: Int)] {
        let regions = foldRegions().regions
        let rootOffset = FoldScanner.root(of: regions, in: string as NSString) == nil ? 1 : 0
        return regions.map { ($0, $0.depth + rootOffset) }
    }

    /// Folds every block, leaving a JSON root open so its keys show. Unfolding one block
    /// then reveals its children still folded, for drilling down level by level.
    func foldAll() {
        setFolds(foldLevels().filter { $0.level >= 1 }.map(\.region.foldRange))
    }

    /// Shows `depth` levels: folds every block at that level and opens everything above it.
    func collapse(toDepth depth: Int) {
        setFolds(foldLevels().filter { $0.level == depth }.map(\.region.foldRange))
    }

    func invalidateFoldDisplay(_ range: NSRange) {
        guard let lm = layoutManager else { return }
        let length = (string as NSString).length
        let start = min(max(range.location - 1, 0), length)
        let r = NSRange(location: start, length: min(NSMaxRange(range) + 1, length) - start)
        lm.invalidateGlyphs(forCharacterRange: r, changeInLength: 0, actualCharacterRange: nil)
        lm.invalidateLayout(forCharacterRange: r, actualCharacterRange: nil)
        needsDisplay = true
        enclosingScrollView?.verticalRulerView?.needsDisplay = true
    }

    /// Keeps folds attached to their brackets as text is edited: folds after the edit shift,
    /// and a fold whose brackets or contents were touched opens. `editedRange` is post-edit.
    func adjustFolds(forEditAt editedRange: NSRange, changeInLength delta: Int) {
        guard !folds.isEmpty else { return }
        let start = editedRange.location
        let oldEnd = NSMaxRange(editedRange) - delta
        var kept: [NSRange] = []
        var opened: [NSRange] = []
        for f in folds {
            let opener = f.location - 1, closer = NSMaxRange(f)
            if oldEnd <= opener {
                kept.append(NSRange(location: f.location + delta, length: f.length))
            } else if start > closer {
                kept.append(f)
            } else {
                let from = min(opener, start)
                opened.append(NSRange(location: from, length: max(max(closer, oldEnd) + delta + 1 - from, 0)))
            }
        }
        folds = kept
        guard !opened.isEmpty else { return }
        // The text storage is mid-edit; the layout manager can't be invalidated until it's done.
        DispatchQueue.main.async { [weak self] in
            for r in opened { self?.invalidateFoldDisplay(r) }
        }
    }

    /// A caret or selection edge that lands inside hidden text (arrow keys, Find, a click)
    /// opens that fold. Deferred: selection changes arrive mid-edit and mid-layout.
    func scheduleUnfoldCheck() {
        guard !folds.isEmpty, !unfoldCheckPending else { return }
        unfoldCheckPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.unfoldCheckPending = false
            let edges = self.selectedRanges.flatMap { [$0.rangeValue.location, NSMaxRange($0.rangeValue)] }
            let hit = self.folds.filter { f in edges.contains { f.location < $0 && $0 < NSMaxRange(f) } }
            if !hit.isEmpty { self.setFolds(self.folds.filter { !hit.contains($0) }) }
        }
    }

    /// After folding, a caret left inside the hidden text moves to just after the opening bracket.
    private func moveSelectionOutOfFolds() {
        let sel = selectedRange()
        guard let f = visibleFold(atOrBefore: sel.location), f.location < sel.location, sel.location < NSMaxRange(f) else { return }
        setSelectedRange(NSRange(location: f.location, length: 0))
    }

    func removeAllFoldsForReload() {
        folds = []
        regionCache = nil
    }

    // MARK: Placeholder

    private var placeholderWidth: CGFloat {
        let font = self.font ?? .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        return ceil((" " as NSString).size(withAttributes: [.font: font]).width * 3 + 6)
    }

    /// Rect of a fold's ⋯ pill, in view coordinates.
    private func placeholderRect(for fold: NSRange) -> NSRect? {
        guard let lm = layoutManager, let tc = textContainer, fold.location < (textStorage?.length ?? 0) else { return nil }
        let glyph = lm.glyphIndexForCharacter(at: fold.location)
        guard glyph < lm.numberOfGlyphs else { return nil }
        let rect = lm.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: tc)
        guard rect.width > 0 else { return nil }
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y).insetBy(dx: 2, dy: 1.5)
    }

    /// Visible folds whose placeholders could fall within `rect` (view coordinates).
    private func visibleFolds(in rect: NSRect) -> [NSRange] {
        guard !visibleFolds.isEmpty, let lm = layoutManager, let tc = textContainer else { return [] }
        let containerRect = rect.offsetBy(dx: -textContainerOrigin.x, dy: -textContainerOrigin.y)
        let glyphs = lm.glyphRange(forBoundingRect: containerRect, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        return visibleFolds.filter { $0.location >= chars.location && $0.location <= NSMaxRange(chars) }
    }

    func drawFoldPlaceholders(in dirtyRect: NSRect) {
        let folds = visibleFolds(in: dirtyRect)
        guard !folds.isEmpty else { return }
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let size = font?.pointSize ?? NSFont.systemFontSize
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * 0.85, weight: .heavy),
            .foregroundColor: isDark ? AppTheme.teal : (AppTheme.teal.blended(withFraction: 0.35, of: .black) ?? AppTheme.teal)
        ]
        let label = "⋯" as NSString
        let labelSize = label.size(withAttributes: attrs)
        for f in folds {
            guard let rect = placeholderRect(for: f), rect.intersects(dirtyRect) else { continue }
            AppTheme.teal.withAlphaComponent(isDark ? 0.22 : 0.16).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            label.draw(at: NSPoint(x: rect.midX - labelSize.width / 2, y: rect.midY - labelSize.height / 2), withAttributes: attrs)
        }
    }

    /// The fold whose ⋯ pill is under `point` (view coordinates).
    func fold(withPlaceholderAt point: NSPoint) -> NSRange? {
        guard !visibleFolds.isEmpty else { return nil }
        let hitArea = NSRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
        return visibleFolds(in: hitArea).first { placeholderRect(for: $0)?.contains(point) == true }
    }

    // MARK: NSLayoutManagerDelegate

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                       characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont,
                       forGlyphRange glyphRange: NSRange) -> Int {
        let count = glyphRange.length
        guard count > 0, !visibleFolds.isEmpty else { return 0 }
        let first = charIndexes[0], last = charIndexes[count - 1]
        // Visible folds are sorted and disjoint, so only the last one starting in or before
        // this batch can overlap it.
        guard let candidate = visibleFold(atOrBefore: last), NSMaxRange(candidate) > first else { return 0 }
        var properties = Array(UnsafeBufferPointer(start: props, count: count))
        for i in 0..<count {
            switch foldState(at: charIndexes[i]) {
            case .visible: break
            case .placeholder: properties[i] = .controlCharacter
            case .hidden: properties[i] = properties[i].contains(.controlCharacter) ? .controlCharacter : .null
            }
        }
        layoutManager.setGlyphs(glyphs, properties: properties, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
        return count
    }

    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        switch foldState(at: charIndex) {
        case .visible: return action
        case .placeholder: return .whitespace
        case .hidden: return .zeroAdvancement
        }
    }

    func layoutManager(_ layoutManager: NSLayoutManager, boundingBoxForControlGlyphAt glyphIndex: Int,
                       for textContainer: NSTextContainer, proposedLineFragment proposedRect: NSRect,
                       glyphPosition: NSPoint, characterIndex charIndex: Int) -> NSRect {
        guard foldState(at: charIndex) == .placeholder else {
            return NSRect(x: glyphPosition.x, y: 0, width: 0, height: proposedRect.height)
        }
        return NSRect(x: glyphPosition.x, y: 0, width: placeholderWidth, height: proposedRect.height)
    }
}
