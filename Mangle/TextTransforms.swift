import Foundation

/// Thrown by a transform to abort with a message shown to the user.
nonisolated struct TransformError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - Indentation

nonisolated enum Indentation: Hashable {
    case spaces(Int)
    case tabs

    var unit: String {
        switch self {
        case .spaces(let n): return String(repeating: " ", count: max(n, 1))
        case .tabs: return "\t"
        }
    }

    var label: String {
        switch self {
        case .spaces(let n): return "Spaces: \(n)"
        case .tabs: return "Tabs"
        }
    }

    @MainActor static var defaultForSettings: Indentation {
        let settings = SettingsManager.shared
        return settings.useTabs ? .tabs : .spaces(settings.tabSize)
    }

    /// Guesses the document's indentation from its first few thousand lines: tabs if most
    /// indented lines start with a tab, otherwise the most common step between successive
    /// space indents. Returns nil when there's no indentation to go on.
    static func detect(in text: String) -> Indentation? {
        var tabLines = 0, spaceLines = 0
        var stepCounts: [Int: Int] = [:]
        var previousIndent = 0
        var linesSeen = 0
        // split() is eager, so sample a prefix rather than splitting a multi-MB paste.
        let sample = text.utf16.count > 200_000 ? Substring(text.prefix(200_000)) : Substring(text)
        for line in sample.split(separator: "\n", omittingEmptySubsequences: false) {
            linesSeen += 1
            if linesSeen > 5_000 { break }
            guard let first = line.first, line.contains(where: { $0 != " " && $0 != "\t" && $0 != "\r" }) else { continue }
            if first == "\t" { tabLines += 1; continue }
            let indent = line.prefix(while: { $0 == " " }).count
            if indent > 0 { spaceLines += 1 }
            let step = abs(indent - previousIndent)
            if step >= 2 && step <= 8 { stepCounts[step, default: 0] += 1 }
            previousIndent = indent
        }
        if tabLines == 0 && spaceLines == 0 { return nil }
        if tabLines > spaceLines { return .tabs }
        guard let best = stepCounts.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }) else { return nil }
        return .spaces(best.key)
    }
}

// MARK: - Line endings

nonisolated enum LineEnding: String {
    case lf = "LF", crlf = "CRLF", cr = "CR", mixed = "Mixed"

    /// Scans UTF-16 once; defaults to LF for text without line breaks.
    static func detect(in text: String) -> LineEnding {
        var lf = 0, crlf = 0, cr = 0
        var previousWasCR = false
        for unit in text.utf16 {
            if unit == 10 {
                if previousWasCR { crlf += 1; cr -= 1 } else { lf += 1 }
            } else if unit == 13 {
                cr += 1
            }
            previousWasCR = unit == 13
        }
        let kinds = [lf > 0, crlf > 0, cr > 0].filter { $0 }.count
        if kinds > 1 { return .mixed }
        if crlf > 0 { return .crlf }
        if cr > 0 { return .cr }
        return .lf
    }
}

// MARK: - Comments

nonisolated enum CommentSyntax {
    case line(String)
    case block(open: String, close: String)

    static func forLanguage(_ language: String) -> CommentSyntax? {
        switch language {
        case "c", "cpp", "java", "javascript", "typescript", "swift", "kotlin", "go", "rust", "php", "scss", "less":
            return .line("//")
        case "python", "ruby", "bash", "perl", "yaml", "graphql":
            return .line("#")
        case "sql":
            return .line("--")
        case "css":
            return .block(open: "/*", close: "*/")
        case "xml", "markdown":
            return .block(open: "<!--", close: "-->")
        default:
            return nil
        }
    }
}

// MARK: - Transforms

/// Pure text transforms used by the Transform menu and the command palette. Each takes the
/// target text (the selection, its full lines, or the whole document) and returns the result.
nonisolated enum TextTransforms {

    // MARK: Whitespace

    static func trimTrailingWhitespace(_ text: String) -> String {
        // Trailing whitespace only — dedenting is Normalize Indentation's job.
        text.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .joined(separator: "\n")
    }

    static func normalizeIndentation(_ text: String, tabSize: Int) -> String {
        let expandedLines = text.components(separatedBy: "\n").map {
            $0.replacingOccurrences(of: "\t", with: String(repeating: " ", count: tabSize))
        }
        let minIndent = expandedLines
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix(while: { $0 == " " }).count }
            .min() ?? 0
        return expandedLines.map { line in
            line.count >= minIndent ? String(line.dropFirst(minIndent)) : line
        }.joined(separator: "\n")
    }

    static func removeAllIndentation(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }

    static func removeBlankLines(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .joined(separator: "\n")
    }

    /// Expands to the next tab stop rather than a fixed width, so tabs that appear mid-line
    /// (aligned comments, table-ish pasted data) stay aligned.
    static func tabsToSpaces(_ text: String, tabSize: Int) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            var result = ""
            var column = 0
            for ch in line {
                if ch == "\t" {
                    let toAdd = tabSize - (column % tabSize)
                    result += String(repeating: " ", count: toAdd)
                    column += toAdd
                } else {
                    result.append(ch)
                    column += 1
                }
            }
            return result
        }.joined(separator: "\n")
    }

    static func spacesToTabs(_ text: String, tabSize: Int) -> String {
        text.components(separatedBy: "\n").map { line in
            let leadingSpaces = line.prefix(while: { $0 == " " }).count
            return String(repeating: "\t", count: leadingSpaces / tabSize)
            + String(repeating: " ", count: leadingSpaces % tabSize)
            + line.dropFirst(leadingSpaces)
        }.joined(separator: "\n")
    }

    /// Re-expresses each line's leading indentation in `target` units, preserving levels.
    static func reindent(_ text: String, from source: Indentation, to target: Indentation, tabSize: Int) -> String {
        let sourceWidth: Int = { if case .spaces(let n) = source { return max(n, 1) }; return max(tabSize, 1) }()
        return text.components(separatedBy: "\n").map { line in
            var columns = 0
            var consumed = 0
            for ch in line {
                if ch == " " { columns += 1 }
                else if ch == "\t" { columns += sourceWidth - (columns % sourceWidth) }
                else { break }
                consumed += 1
            }
            guard consumed > 0 else { return line }
            let levels = columns / sourceWidth
            let remainder = columns % sourceWidth
            return String(repeating: target.unit, count: levels) + String(repeating: " ", count: remainder) + line.dropFirst(consumed)
        }.joined(separator: "\n")
    }
    
    // MARK: Case

    static func titleCase(_ text: String) -> String {
        let small: Set<String> = ["a","an","the","and","but","or","for","nor","so","yet","at","by","in","of","on","to","up","as"]
        return text.components(separatedBy: "\n").map { line in
            let words = line.components(separatedBy: " ")
            let lastIndex = words.count - 1
            return words.enumerated().map { i, word in
                let lower = word.lowercased()
                // First and last word are always capitalized, per standard title-case rules.
                if i > 0 && i < lastIndex && small.contains(lower) { return lower }
                return word.prefix(1).uppercased() + word.dropFirst().lowercased()
            }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    static func camelCase(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            let words = splitIntoWords(line)
            guard let first = words.first else { return line }
            return ([first] + words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst() }).joined()
        }.joined(separator: "\n")
    }

    static func snakeCase(_ text: String) -> String {
        text.components(separatedBy: "\n").map { splitIntoWords($0).joined(separator: "_") }.joined(separator: "\n")
    }

    static func kebabCase(_ text: String) -> String {
        text.components(separatedBy: "\n").map { splitIntoWords($0).joined(separator: "-") }.joined(separator: "\n")
    }

    static func constantCase(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .map { splitIntoWords($0).map { $0.uppercased() }.joined(separator: "_") }
            .joined(separator: "\n")
    }

    /// Splits an identifier into lowercase words, regardless of its current style —
    /// handles snake_case, kebab-case, space-separated, camelCase, and PascalCase
    /// (including acronym runs like "XMLHttpRequest" -> ["xml", "http", "request"]).
    static func splitIntoWords(_ s: String) -> [String] {
        var result = s.replacingOccurrences(of: "[_\\-]+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: "([a-z0-9])([A-Z])", with: "$1 $2", options: .regularExpression)
        result = result.replacingOccurrences(of: "([A-Z]+)([A-Z][a-z])", with: "$1 $2", options: .regularExpression)
        return result.split(separator: " ").map { $0.lowercased() }
    }

    // MARK: Lines

    static func sortLines(_ text: String) -> String {
        text.components(separatedBy: "\n").sorted().joined(separator: "\n")
    }

    /// Case-insensitive, numeric-aware: "item2" sorts before "item10".
    static func sortLinesNatural(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .joined(separator: "\n")
    }

    static func removeDuplicateLines(_ text: String) -> String {
        var seen = Set<String>()
        return text.components(separatedBy: "\n")
            .filter { seen.insert($0).inserted }
            .joined(separator: "\n")
    }

    static func reverseLines(_ text: String) -> String {
        text.components(separatedBy: "\n").reversed().joined(separator: "\n")
    }

    static func joinLines(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first else { return text }
        return lines.dropFirst().reduce(first.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)) { acc, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return acc }
            return acc.isEmpty ? trimmed : acc + " " + trimmed
        }
    }

    // MARK: Line endings

    static func toLF(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    static func toCRLF(_ text: String) -> String {
        toLF(text).replacingOccurrences(of: "\n", with: "\r\n")
    }

    static func toCR(_ text: String) -> String {
        toLF(text).replacingOccurrences(of: "\n", with: "\r")
    }

    // MARK: Encode / Decode

    static func base64Encode(_ text: String) -> String {
        Data(text.utf8).base64EncodedString()
    }

    static func base64Decode(_ text: String) throws -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Accept base64url and missing padding too.
        s = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s), let decoded = String(data: data, encoding: .utf8) else {
            throw TransformError("Decode failed — invalid Base64")
        }
        return decoded
    }

    static func urlEncode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
    }

    static func urlDecode(_ text: String) throws -> String {
        guard let decoded = text.removingPercentEncoding else {
            throw TransformError("Decode failed — invalid percent-encoding")
        }
        return decoded
    }

    static func htmlEntityEncode(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// Decodes named (&amp; &lt; &gt; &quot; &apos; &nbsp;) and numeric (&#39; &#x27;) HTML
    /// entities in a single pass over the original text — avoids the double-decode bugs
    /// sequential find-replace would cause on inputs like "&amp;lt;" (double-encoded input).
    static func htmlEntityDecode(_ text: String) -> String {
        let named: [String: Character] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "
        ]
        guard let regex = try? NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);") else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var output = ""
        var lastEnd = 0
        for m in matches {
            output += nsText.substring(with: NSRange(location: lastEnd, length: m.range.location - lastEnd))
            let inner = nsText.substring(with: m.range(at: 1))
            var replacement: String?
            if inner.hasPrefix("#x") || inner.hasPrefix("#X") {
                if let v = UInt32(inner.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(v) {
                    replacement = String(Character(scalar))
                }
            } else if inner.hasPrefix("#") {
                if let v = UInt32(inner.dropFirst()), let scalar = Unicode.Scalar(v) {
                    replacement = String(Character(scalar))
                }
            } else if let ch = named[inner.lowercased()] {
                replacement = String(ch)
            }
            output += replacement ?? nsText.substring(with: m.range)
            lastEnd = m.range.location + m.range.length
        }
        output += nsText.substring(with: NSRange(location: lastEnd, length: nsText.length - lastEnd))
        return output
    }

    // MARK: JSON

    private static func parseJSON(_ text: String) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
        } catch {
            throw TransformError("Invalid JSON — \(jsonErrorDescription(error))")
        }
    }

    private static func jsonErrorDescription(_ error: Error) -> String {
        let ns = error as NSError
        if let debug = ns.userInfo[NSDebugDescriptionErrorKey] as? String { return debug }
        return ns.localizedDescription
    }

    /// nil when valid, otherwise a short error description.
    static func validateJSON(_ text: String) -> String? {
        do { _ = try parseJSON(text); return nil } catch let e as TransformError { return e.message } catch { return "Invalid JSON" }
    }

    /// Removes insignificant whitespace without reparsing, so key order and number formatting
    /// are preserved exactly (JSONSerialization would reorder keys).
    static func minifyJSON(_ text: String) throws -> String {
        _ = try parseJSON(text)
        var out = String.UnicodeScalarView()
        var inString = false
        var escaped = false
        for scalar in text.unicodeScalars {
            if inString {
                out.append(scalar)
                if escaped { escaped = false }
                else if scalar == "\\" { escaped = true }
                else if scalar == "\"" { inString = false }
            } else if scalar == "\"" {
                inString = true
                out.append(scalar)
            } else if !(scalar == " " || scalar == "\n" || scalar == "\r" || scalar == "\t") {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// Pretty-prints preserving key order and number formatting (re-serializing through
    /// JSONSerialization would reorder keys).
    static func prettyPrintJSON(_ text: String, indentation: Indentation) throws -> String {
        let compact = Array(try minifyJSON(text).unicodeScalars)
        let unit = indentation.unit
        var out = String.UnicodeScalarView()
        var level = 0
        var inString = false
        var escaped = false
        func newline() {
            out.append("\n")
            out.append(contentsOf: String(repeating: unit, count: level).unicodeScalars)
        }
        var i = 0
        while i < compact.count {
            let c = compact[i]
            if inString {
                out.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { inString = false }
                i += 1
                continue
            }
            switch c {
            case "\"":
                inString = true
                out.append(c)
            case "{", "[":
                out.append(c)
                let closer: Unicode.Scalar = c == "{" ? "}" : "]"
                if i + 1 < compact.count, compact[i + 1] == closer {
                    out.append(closer)   // empty container stays on one line
                    i += 1
                } else {
                    level += 1
                    newline()
                }
            case "}", "]":
                level -= 1
                newline()
                out.append(c)
            case ",":
                out.append(c)
                newline()
            case ":":
                out.append(contentsOf: ": ".unicodeScalars)
            default:
                out.append(c)
            }
            i += 1
        }
        return String(out)
    }
    
    /// Pretty-prints with keys sorted, re-indented to the document's indentation.
    static func sortJSONKeys(_ text: String, indentation: Indentation) throws -> String {
        let object = try parseJSON(text)
        // Serialize compactly with sorted keys, then format with our printer so output matches
        // Pretty Print JSON (JSONSerialization's own pretty mode writes `"a" : 1` and splits `{}`).
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])
        return try prettyPrintJSON(String(decoding: data, as: UTF8.self), indentation: indentation)
    }

    /// Escapes text as the contents of a JSON string literal (no surrounding quotes).
    static func escapeJSONString(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// Unescapes a JSON string literal — with or without its surrounding quotes.
    static func unescapeJSONString(_ text: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let literal = trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2 ? trimmed : "\"\(trimmed)\""
        guard let value = try? JSONSerialization.jsonObject(with: Data(literal.utf8), options: [.fragmentsAllowed]) as? String else {
            throw TransformError("Unescape failed — not a valid JSON string")
        }
        return value
    }

    // MARK: JWT

    /// Decodes a JWT's header and payload into readable JSON, annotating standard
    /// timestamp claims (iat/nbf/exp) with their dates. The signature isn't verified.
    static func decodeJWT(_ text: String, indentation: Indentation) throws -> String {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "Bearer ", with: "")
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { throw TransformError("Not a JWT — expected header.payload.signature") }

        func decodePart(_ part: Substring, name: String) throws -> String {
            guard let json = try? base64Decode(String(part)) else {
                throw TransformError("JWT \(name) isn't valid Base64URL")
            }
            return (try? sortJSONKeys(json, indentation: indentation)) ?? json
        }
        let header = try decodePart(parts[0], name: "header")
        let payload = try decodePart(parts[1], name: "payload")

        var notes: [String] = []
        if let data = try? base64Decode(String(parts[1])).data(using: .utf8),
           let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let formatter = ISO8601DateFormatter()
            for claim in ["iat", "nbf", "exp"] {
                if let seconds = claims[claim] as? Double {
                    let date = Date(timeIntervalSince1970: seconds)
                    var note = "// \(claim): \(formatter.string(from: date))"
                    if claim == "exp" { note += date < Date() ? " (expired)" : " (valid)" }
                    notes.append(note)
                }
            }
        }
        var output = "// Header\n\(header)\n\n// Payload\n\(payload)"
        if !notes.isEmpty { output += "\n\n" + notes.joined(separator: "\n") }
        return output
    }

    // MARK: Comments

    /// Comments or uncomments every non-blank line in `text`. Uncomments only when every
    /// non-blank line is already commented, like Xcode/VS Code.
    static func toggleComment(_ text: String, syntax: CommentSyntax) -> String {
        let lines = text.components(separatedBy: "\n")
        let contentLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !contentLines.isEmpty else { return text }

        func splitIndent(_ line: String) -> (indent: Substring, body: Substring) {
            let indent = line.prefix(while: { $0 == " " || $0 == "\t" })
            return (indent, line[indent.endIndex...])
        }

        switch syntax {
        case .line(let prefix):
            let allCommented = contentLines.allSatisfy { splitIndent($0).body.hasPrefix(prefix) }
            if allCommented {
                return lines.map { line in
                    let (indent, body) = splitIndent(line)
                    guard body.hasPrefix(prefix) else { return line }
                    var rest = body.dropFirst(prefix.count)
                    if rest.first == " " { rest = rest.dropFirst() }
                    return String(indent) + rest
                }.joined(separator: "\n")
            }
            // Insert at the shallowest indent so the comment markers line up.
            let minIndent = contentLines.map { splitIndent($0).indent.count }.min() ?? 0
            return lines.map { line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                let idx = line.index(line.startIndex, offsetBy: minIndent)
                return String(line[..<idx]) + prefix + " " + line[idx...]
            }.joined(separator: "\n")

        case .block(let open, let close):
            let allCommented = contentLines.allSatisfy {
                let body = splitIndent($0).body.trimmingCharacters(in: .whitespaces)
                return body.hasPrefix(open) && body.hasSuffix(close)
            }
            return lines.map { line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                let (indent, body) = splitIndent(line)
                if allCommented {
                    var inner = body.trimmingCharacters(in: .whitespaces)
                    inner = String(inner.dropFirst(open.count).dropLast(close.count))
                    return String(indent) + inner.trimmingCharacters(in: .whitespaces)
                }
                return String(indent) + open + " " + body + " " + close
            }.joined(separator: "\n")
        }
    }

    // MARK: Fuzzy matching

    /// Subsequence fuzzy match score (higher is better), nil when `query` doesn't match.
    /// Rewards consecutive characters and matches at word starts.
    static func fuzzyScore(_ query: String, in candidate: String) -> Int? {
        let q = Array(query.lowercased().filter { $0 != " " })
        guard !q.isEmpty else { return 0 }
        let c = Array(candidate.lowercased())
        var score = 0
        var qi = 0
        var lastMatch = -2
        for (i, ch) in c.enumerated() where qi < q.count {
            guard ch == q[qi] else { continue }
            var points = 1
            if i == lastMatch + 1 { points += 4 }
            if i == 0 || !(c[i - 1].isLetter || c[i - 1].isNumber) { points += 6 }
            score += points
            lastMatch = i
            qi += 1
        }
        guard qi == q.count else { return nil }
        return score * 100 / max(c.count, 1) + score
    }
}

// MARK: - Code Folding

/// A multi-line `{…}` or `[…]` block that can be folded.
nonisolated struct FoldRegion: Equatable {
    let opener: Int
    let closer: Int
    /// 1-based line of the opening bracket.
    let line: Int
    /// Bracket nesting depth, 0 for the outermost blocks.
    let depth: Int

    /// The hidden text: everything between the brackets, so a folded line reads `"items": [⋯]`.
    var foldRange: NSRange { NSRange(location: opener + 1, length: closer - opener - 1) }
}

nonisolated enum FoldScanner {
    /// Bigger documents aren't scanned — they'd cost a noticeable pause per edit.
    static let maxLength = 2_000_000

    /// Bracket blocks spanning more than one line, sorted by opener. Brackets inside
    /// double-quoted strings are skipped when `skipStrings` is set (code, not prose).
    static func regions(in text: NSString, skipStrings: Bool) -> [FoldRegion] {
        let length = text.length
        guard length > 0, length <= maxLength else { return [] }
        var result: [FoldRegion] = []
        var stack: [(bracket: unichar, index: Int, line: Int)] = []
        var line = 1
        var inString = false
        var escaped = false
        let chunk = 4096
        var location = 0
        withUnsafeTemporaryAllocation(of: unichar.self, capacity: chunk) { buf in
            guard let base = buf.baseAddress else { return }
            while location < length {
                let n = min(chunk, length - location)
                text.getCharacters(base, range: NSRange(location: location, length: n))
                for i in 0..<n {
                    let c = base[i]
                    if c == 10 {
                        line += 1
                        // Strings don't span lines; an unterminated quote must not swallow the rest.
                        inString = false
                        escaped = false
                        continue
                    }
                    if inString {
                        if escaped { escaped = false }
                        else if c == 92 { escaped = true }       // backslash
                        else if c == 34 { inString = false }     // "
                        continue
                    }
                    switch c {
                    case 34 where skipStrings:
                        inString = true
                    case 123, 91: // { [
                        stack.append((c, location + i, line))
                    case 125, 93: // } ]
                        let opener: unichar = c == 125 ? 123 : 91
                        if let k = stack.lastIndex(where: { $0.bracket == opener }) {
                            let open = stack[k]
                            stack.removeSubrange(k...)
                            if line > open.line {
                                result.append(FoldRegion(opener: open.index, closer: location + i, line: open.line, depth: k))
                            }
                        }
                    default:
                        break
                    }
                }
                location += n
            }
        }
        return result.sorted { $0.opener < $1.opener }
    }

    /// The single block wrapping the whole document (a JSON object or array), if there is one.
    static func root(of regions: [FoldRegion], in text: NSString) -> FoldRegion? {
        let top = regions.filter { $0.depth == 0 }
        guard top.count == 1, let region = top.first else { return nil }
        let ws = CharacterSet.whitespacesAndNewlines
        let before = text.substring(to: region.opener)
        let after = text.substring(from: region.closer + 1)
        guard before.trimmingCharacters(in: ws).isEmpty, after.trimmingCharacters(in: ws).isEmpty else { return nil }
        return region
    }
}

// MARK: - JSON Path

nonisolated extension TextTransforms {
    /// The path to the JSON value at `location`, e.g. `data.users[0].email`. Empty at the root.
    /// Scans tolerantly up to the caret, so it works on documents that don't fully parse.
    static func jsonPath(in text: NSString, at location: Int) -> String {
        enum Container {
            case object(key: String?)
            case array(index: Int, hasValue: Bool)
        }
        var stack: [Container] = []
        var expectingKey = false
        let length = text.length
        let end = min(max(location, 0), length)

        func markValue() {
            if case .array(let index, _) = stack.last { stack[stack.count - 1] = .array(index: index, hasValue: true) }
        }

        var i = 0
        scan: while i < length {
            let c = text.character(at: i)
            if i >= end {
                // The caret sits just before this character: it counts only if it starts a key or value.
                switch c {
                case 34: break
                case 32, 9, 10, 13, 44, 58, 93, 125: break scan
                default: markValue(); break scan
                }
            }
            switch c {
            case 34: // a string: read it whole, even past the caret, so a key under the caret counts
                var j = i + 1
                var escaped = false
                while j < length {
                    let d = text.character(at: j)
                    if escaped { escaped = false }
                    else if d == 92 { escaped = true }
                    else if d == 34 || d == 10 { break }
                    j += 1
                }
                if expectingKey, case .object = stack.last {
                    let raw = text.substring(with: NSRange(location: i + 1, length: max(j - i - 1, 0)))
                    let key = (try? JSONSerialization.jsonObject(with: Data("\"\(raw)\"".utf8), options: .fragmentsAllowed) as? String) ?? raw
                    stack[stack.count - 1] = .object(key: key)
                } else {
                    markValue()
                }
                if j >= end { break scan }
                i = j + 1
                continue
            case 123: // {
                markValue()
                stack.append(.object(key: nil))
                expectingKey = true
            case 91: // [
                markValue()
                stack.append(.array(index: 0, hasValue: false))
                expectingKey = false
            case 125, 93: // } ]
                if !stack.isEmpty { stack.removeLast() }
                expectingKey = false
            case 58: // :
                expectingKey = false
            case 44: // ,
                switch stack.last {
                case .object?:
                    stack[stack.count - 1] = .object(key: nil)
                    expectingKey = true
                case .array(let index, _)?:
                    stack[stack.count - 1] = .array(index: index + 1, hasValue: false)
                case nil:
                    break
                }
            case 32, 9, 10, 13:
                break
            default:
                markValue()
            }
            i += 1
        }

        var path = ""
        for container in stack {
            switch container {
            case .object(let key?):
                if key.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*$"#, options: .regularExpression) != nil {
                    path += path.isEmpty ? key : "." + key
                } else {
                    path += "[\"" + escapeJSONString(key) + "\"]"
                }
            case .array(let index, true):
                path += "[\(index)]"
            case .object(nil), .array(_, false):
                return path
            }
        }
        return path
    }
}
