import Foundation
import JavaScriptCore

// MARK: - Errors

enum PrettierError: Error, LocalizedError {
    case unsupportedLanguage
    case syntaxError(String)
    case formatFailed
    
    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage: return "Language not supported by formatter"
        case .syntaxError(let msg): return "Syntax error: \(msg)"
        case .formatFailed: return "Format failed"
        }
    }
}

// MARK: - Formatter

final class PrettierFormatter: @unchecked Sendable {
    
    static let shared = PrettierFormatter()
    
    // Serial queue — all JSContext work runs here, naturally serialising load + format calls.
    private let q = DispatchQueue(label: "co.liamo.mangle.prettier", qos: .userInitiated)
    private var ctx: JSContext?
    
    private init() {
        q.async { self.load() }
    }
    
    // MARK: Public
    
    /// Languages that can be formatted.
    static let supportedLanguages: Set<String> = [
        "javascript", "typescript", "css", "scss", "less",
        "html", "markdown", "yaml", "graphql"
    ]
    
    func canFormat(language: String) -> Bool {
        Self.supportedLanguages.contains(language)
    }
    
    func format(code: String, language: String, tabSize: Int) async throws -> String {
        guard let parser = prettierParser(for: language) else {
            throw PrettierError.unsupportedLanguage
        }
        
        return try await withCheckedThrowingContinuation { cont in
            // Queued after load(), so context is ready when this runs.
            q.async {
                guard let ctx = self.ctx else {
                    cont.resume(throwing: PrettierError.formatFailed)
                    return
                }
                
                guard let fn = ctx.objectForKeyedSubscript("__fmt") else {
                    cont.resume(throwing: PrettierError.formatFailed)
                    return
                }
                
                let result = fn.call(withArguments: [code, parser, tabSize])
                
                // Wrapper returns { ok: string } or { err: string }
                if let errMsg = result?.objectForKeyedSubscript("err")?.toString(),
                   errMsg != "undefined", errMsg != "null", !errMsg.isEmpty {
                    cont.resume(throwing: PrettierError.syntaxError(errMsg))
                    return
                }
                
                if let formatted = result?.objectForKeyedSubscript("ok")?.toString(),
                   formatted != "undefined", !formatted.isEmpty {
                    cont.resume(returning: formatted)
                } else {
                    cont.resume(throwing: PrettierError.formatFailed)
                }
            }
        }
    }
    
    // MARK: Private
    
    private func load() {
        let jsCtx = JSContext()!
        jsCtx.exceptionHandler = { _, _ in }
        
        // Polyfill globals expected by the UMD bundles
        jsCtx.evaluateScript("var globalThis = this; var global = this; var self = this;")
        
        let files = [
            "prettier.standalone",
            "parser-babel",
            "parser-typescript",
            "parser-postcss",
            "parser-html",
            "parser-markdown",
            "parser-yaml",
            "parser-graphql",
        ]
        
        for name in files {
            guard let url = Bundle.main.url(forResource: name, withExtension: "js"),
                  let src = try? String(contentsOf: url, encoding: .utf8) else {
                return
            }
            jsCtx.evaluateScript(src)
        }
        
        // Thin wrapper so we can pass arguments cleanly and catch errors.
        jsCtx.evaluateScript("""
        function __fmt(code, parser, tabWidth) {
            try {
                var plugins = [];
                if (typeof prettierPlugins !== 'undefined') {
                    Object.keys(prettierPlugins).forEach(function(k) {
                        plugins.push(prettierPlugins[k]);
                    });
                }
                var result = prettier.format(code, {
                    parser:     parser,
                    plugins:    plugins,
                    tabWidth:   tabWidth,
                    useTabs:    false,
                    printWidth: 80,
                    singleQuote: false,
                });
                return { ok: result };
            } catch(e) {
                return { err: String(e.message || e) };
            }
        }
        """)
        
        ctx = jsCtx
    }
    
    private func prettierParser(for language: String) -> String? {
        switch language {
        case "javascript", "jsx": return "babel"
        case "typescript", "tsx": return "typescript"
        case "css":               return "css"
        case "scss":              return "scss"
        case "less":              return "less"
        case "html":              return "html"
        case "markdown":          return "markdown"
        case "yaml":              return "yaml"
        case "graphql":           return "graphql"
        default:                  return nil
        }
    }
}
