import Foundation

/// The fixed command phrases. Used for "Exact commands" mode, and in AI mode to open an app
/// while the user is still speaking. Dictated note text is data, never executable code.
enum Grammar {
    enum Action: Equatable {
        case wait(reason: String)
        case cancel
        case open(app: String, bundle: String, hasNote: Bool)
        case note(body: String)
    }

    struct Decision: Equatable {
        let action: Action
        /// Identifies the side effect, so repeated partial transcripts don't repeat it.
        let key: String?
    }

    static let apps: [String: (name: String, bundle: String)] = [
        "notes": ("Notes", "com.apple.Notes"),
        "safari": ("Safari", "com.apple.Safari"),
        "chrome": ("Google Chrome", "com.google.Chrome"),
        "google chrome": ("Google Chrome", "com.google.Chrome"),
        "finder": ("Finder", "com.apple.finder"),
        "music": ("Music", "com.apple.Music"),
        "spotify": ("Spotify", "com.spotify.client"),
    ]

    static let openPattern = Pattern(#"^(?:please\s+)?(?:open|launch|start)\s+(?:the\s+)?(google chrome|chrome|notes|safari|finder|music|spotify)(?:\s+app)?(?=$|[\s,.!?])"#)
    static let notePattern = Pattern(#"^(?:(?:please\s+)?(?:open|launch|start)\s+(?:the\s+)?notes(?:\s+app)?\s+(?:and|then)\s+)?(?:please\s+)?(?:create|make|write)\s+(?:a\s+)?(?:new\s+)?note\s+(?:saying|that says|with the text)\s+(.+)$"#, dotAll: true)
    static let cancelPattern = Pattern(#"\b(?:cancel|never mind|nevermind|stop listening)\b"#)
    static let correctionPattern = Pattern(#"\b(?:actually|instead|don[’']t|do not|wait)\b"#)

    static func decide(_ raw: String, final: Bool = false, completed: Set<String> = []) -> Decision {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 8000 { return Decision(action: .wait(reason: "Command is too long."), key: nil) }
        // An explicit cancel always cancels. Words inside dictated note content are literal.
        let note = notePattern.firstMatch(in: text)
        let commandPart = note.map { String(text[..<$0.range(at: 1).lowerBound]) } ?? text
        if cancelPattern.contains(commandPart) { return Decision(action: .cancel, key: nil) }
        if correctionPattern.contains(commandPart) {
            return Decision(action: .wait(reason: "Correction heard. Start a fresh command."), key: nil)
        }
        let target = openPattern.firstMatch(in: text).map { apps[$0.group(1).lowercased()]! } ?? (note != nil ? apps["notes"] : nil)
        if let target {
            let key = "open:" + target.bundle
            if !completed.contains(key) {
                return Decision(action: .open(app: target.name, bundle: target.bundle, hasNote: note != nil), key: key)
            }
        }
        if let note, final {
            let body = note.group(1).trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty && !completed.contains("note") { return Decision(action: .note(body: body), key: "note") }
        }
        return Decision(action: .wait(reason: note != nil ? "Finish listening to save the note." : "Waiting for a supported command."), key: nil)
    }
}

extension Grammar {
    /// What to do with a partial transcript while the user is still speaking. In AI mode nothing runs
    /// until they finish, so a later "actually…" can still change the plan; only "never mind" acts early.
    static func decideWhileSpeaking(_ text: String, aiMode: Bool, completed: Set<String> = []) -> Decision {
        let decision = decide(text, final: false, completed: completed)
        guard aiMode else { return decision }
        return decision.action == .cancel ? decision : Decision(action: .wait(reason: "Listening…"), key: nil)
    }
}

/// A small case-insensitive wrapper around NSRegularExpression.
struct Pattern {
    let expression: NSRegularExpression

    init(_ pattern: String, dotAll: Bool = false) {
        expression = try! NSRegularExpression(pattern: pattern, options: dotAll ? [.caseInsensitive, .dotMatchesLineSeparators] : [.caseInsensitive])
    }

    struct Match {
        let text: String
        let result: NSTextCheckingResult
        func range(at index: Int) -> Range<String.Index> { Range(result.range(at: index), in: text)! }
        func group(_ index: Int) -> String { String(text[range(at: index)]) }
    }

    func firstMatch(in text: String) -> Match? {
        expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)).map { Match(text: text, result: $0) }
    }

    func contains(_ text: String) -> Bool { firstMatch(in: text) != nil }
}
