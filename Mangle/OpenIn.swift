import AppKit

/// Apps the palette can hand the document to ("Open in: Visual Studio Code"). Only the
/// installed ones are offered.
enum OpenIn {
    struct App {
        let name: String
        let bundleID: String
        /// Notes imports plain text but nothing it doesn't recognise, so it always gets `.txt`.
        var plainTextOnly = false
    }

    private static let candidates: [App] = [
        App(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode"),
        App(name: "Cursor", bundleID: "com.todesktop.230313mt7ozwk"),
        App(name: "Zed", bundleID: "dev.zed.Zed"),
        App(name: "Sublime Text", bundleID: "com.sublimetext.4"),
        App(name: "Nova", bundleID: "com.panic.Nova"),
        App(name: "BBEdit", bundleID: "com.barebones.bbedit"),
        App(name: "Xcode", bundleID: "com.apple.dt.Xcode"),
        App(name: "TextEdit", bundleID: "com.apple.TextEdit"),
        App(name: "Notes", bundleID: "com.apple.Notes", plainTextOnly: true),
    ]

    /// Looked up once: the palette rebuilds its command list on every keystroke.
    static let installed: [(app: App, url: URL)] = candidates.compactMap { app in
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID).map { (app, $0) }
    }

    /// Writes `text` to a fresh temporary file named for its language and opens it in `appURL`.
    static func open(_ text: String, language: String, in app: App, at appURL: URL) {
        let ext = app.plainTextOnly ? "txt" : fileExtension(for: language)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Open In", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("Untitled.\(ext)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            AppDelegate.shared?.showToast("Couldn't save a copy for \(app.name)")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open([file], withApplicationAt: appURL, configuration: configuration) { _, error in
            guard error != nil else { return }
            DispatchQueue.main.async { AppDelegate.shared?.showToast("Couldn't open \(app.name)") }
        }
    }

    /// Editors pick their highlighting from the extension.
    static func fileExtension(for language: String) -> String {
        switch language {
        case "bash": return "sh"
        case "c": return "c"
        case "cpp": return "cpp"
        case "css": return "css"
        case "diff": return "diff"
        case "graphql": return "graphql"
        case "go": return "go"
        case "xml": return "html"
        case "java": return "java"
        case "javascript": return "js"
        case "json": return "json"
        case "kotlin": return "kt"
        case "less": return "less"
        case "markdown": return "md"
        case "perl": return "pl"
        case "php": return "php"
        case "python": return "py"
        case "ruby": return "rb"
        case "rust": return "rs"
        case "scss": return "scss"
        case "sql": return "sql"
        case "swift": return "swift"
        case "typescript": return "ts"
        case "yaml": return "yaml"
        default: return "txt"
        }
    }
}
