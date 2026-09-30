import Foundation

/// One validated action. The model only proposes tool calls; `Planner.validate` turns each into a Step
/// the app knows how to run, and anything else is dropped. Dictated text stays data.
enum Step: Equatable {
    case openApp(name: String, path: String, bundle: String)
    case createNote(body: String)
    case createReminder(title: String, due: String?)
    case runShortcut(name: String, input: String?)
    case openURL(String, label: String)
    case setVolume(Int)

    /// Identifies the side effect, so the same action is never run twice for one command.
    var key: String {
        switch self {
        case .openApp(_, _, let bundle): return "open:" + bundle
        case .createNote: return "note"
        case .createReminder(let title, _): return "reminder:" + title.lowercased()
        case .runShortcut(let name, _): return "shortcut:" + name
        case .openURL(let url, _): return "url:" + url.lowercased()
        case .setVolume: return "volume"
        }
    }

    var summary: String {
        switch self {
        case .openApp(let name, _, _): return "Open \(name)"
        case .createNote(let body): return "Create note: " + body.prefix(60)
        case .createReminder(let title, let due): return "Remind me: \(title)" + (due.map { " (\($0.replacingOccurrences(of: "T", with: " ")))" } ?? "")
        case .runShortcut(let name, _): return "Run shortcut \(name)"
        case .openURL(_, let label): return label
        case .setVolume(let percent): return "Set volume to \(percent)%"
        }
    }
}

struct Plan: Equatable {
    var steps: [Step]
    var say: String
}

struct PlannerError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Turns a spoken command into validated steps using a local model served by Ollama.
@MainActor
final class Planner {
    typealias Chat = ([[String: Any]]) async throws -> [String: Any]

    static let maxSteps = 6
    static let tools: [(name: String, description: String, properties: [String: [String: String]], required: [String])] = [
        ("open_app", "Open or switch to an application installed on this Mac.",
         ["name": ["type": "string", "description": "Application name as the user said it, e.g. \"Spotify\"."]], ["name"]),
        ("create_note", "Create a note in Apple Notes.",
         ["body": ["type": "string", "description": "The note text, copied exactly from the user's words."]], ["body"]),
        ("create_reminder", "Create a reminder in Apple Reminders. The app works out the due time itself from what the user said.",
         ["title": ["type": "string", "description": "What to be reminded about, in the user's words, without the time."]], ["title"]),
        ("run_shortcut", "Run one of the user's Apple Shortcuts by name.",
         ["name": ["type": "string", "description": "Exact shortcut name from the available list."],
          "input": ["type": "string", "description": "Optional text to pass to the shortcut."]], ["name"]),
        ("web_search", "Search the web in the default browser.", ["query": ["type": "string"]], ["query"]),
        ("open_url", "Open a website in the default browser.",
         ["url": ["type": "string", "description": "A website address such as youtube.com."]], ["url"]),
        ("set_volume", "Set the Mac output volume.",
         ["percent": ["type": "integer", "description": "0 to 100. Use 0 to mute."]], ["percent"]),
    ]

    static let systemPrompt = """
    You are the command interpreter for Utter, a macOS voice assistant.
    The user's words come from speech recognition and may contain small transcription errors.
    Turn the request into tool calls, in the order they should happen.

    Rules:
    - Only do what the user actually asked. If they negate or cancel ("don't", "never mind"), call no tools.
    - If the user corrects themselves ("open Safari, actually Chrome"), act only on their final intent.
    - For notes and reminders, copy the user's own words exactly. Do not rephrase, summarise or add anything.
    - If the user asks to open an app, call open_app for it, even when a later step uses that app.
    - If the request is a question, conversation, or something no tool can do, call no tools and reply to the user in one short friendly sentence. Never mention tools.
    - Only use shortcut names from this list:
    """

    static let fallbackReply = "I can open apps and websites, search the web, make notes and reminders, run shortcuts and set the volume."
    static let openNotes = Pattern(#"\b(?:open|launch|start)\s+(?:the\s+)?notes\b"#)
    static let negation = Pattern(#"\b(?:don[’']?t|do not|never mind|nevermind|cancel|stop)\b"#)
    static let toolTalk = Pattern(#"\btools?\b|function"#)
    static let addToNote = Pattern(#"^(?:please\s+)?add\s+(.+?)\s+to\s+(?:my|the|a)\s+(?:[\p{L}\p{N}]+\s+)?notes?[.!]?$"#, dotAll: true)
    static let noteBody = Pattern(#"\b(?:note\s+(?:saying|that says|with the text)|(?:jot|write)\s+down(?:\s+that)?|(?:take|make)\s+a\s+note(?:\s+(?:that|saying|of))?)\s*[:,]?\s+(.+)$"#, dotAll: true)

    let model: String
    let server: URL
    var apps: AppCatalog
    var shortcuts: [String]
    private let chatOverride: Chat?

    init(model: String, server: URL, apps: AppCatalog = AppCatalog(), shortcuts: [String] = [], chat: Chat? = nil) {
        self.model = model; self.server = server; self.apps = apps; self.shortcuts = shortcuts; chatOverride = chat
    }

    /// Checks Ollama and the model, loads the model, and caches the system prompt so the first command is fast.
    func warm() async throws -> String {
        do {
            _ = try await post("/api/show", ["model": model], timeout: 10)
        } catch let error as PlannerError {
            throw error
        } catch {
            throw PlannerError("Ollama is not running. Start the Ollama app or run: brew services start ollama")
        }
        _ = try await plan("open notes")
        return "\(model) via Ollama"
    }

    func plan(_ text: String, now: Date = Date()) async throws -> Plan {
        let messages: [[String: Any]] = [
            ["role": "system", "content": Self.systemPrompt + (shortcuts.isEmpty ? "(none)" : shortcuts.map { "\"\($0)\"" }.joined(separator: ", "))],
            ["role": "user", "content": "Command: \(text)"],
        ]
        let message = try await (chatOverride ?? ollamaChat)(messages)
        var steps: [Step] = [], problems: [String] = []
        for call in ((message["tool_calls"] as? [[String: Any]]) ?? []).prefix(Self.maxSteps) {
            let function = call["function"] as? [String: Any] ?? [:]
            var arguments = function["arguments"] as? [String: Any] ?? [:]
            if let json = function["arguments"] as? String, let data = json.data(using: .utf8) {
                arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            }
            switch validate(function["name"] as? String ?? "", arguments, text: text, now: now) {
            case .step(let step) where !steps.contains { $0.key == step.key }: steps.append(step)
            case .refused(let reason): problems.append(reason)
            default: break
            }
        }
        // The model sometimes folds "open Notes" into create_note; keep the explicit open the user asked for.
        if steps.contains(where: { if case .createNote = $0 { return true }; return false }), Self.openNotes.contains(text),
           case .step(let notes) = validate("open_app", ["name": "Notes"], text: text), !steps.contains(where: { $0.key == notes.key }) {
            steps.insert(notes, at: 0)
        }
        var reply = (message["content"] as? String ?? "")
            .replacingOccurrences(of: "(?s)<think>.*?</think>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if steps.isEmpty && (reply.isEmpty || Self.toolTalk.contains(reply)) {
            reply = Self.negation.contains(text) ? "OK, I won’t do anything." : Self.fallbackReply
        }
        let say = problems.isEmpty ? (steps.isEmpty ? String(reply.prefix(200)) : "") : problems.joined(separator: " ")
        return Plan(steps: steps, say: say)
    }

    enum Validation: Equatable { case step(Step), refused(String), skipped }

    func validate(_ tool: String, _ arguments: [String: Any], text: String, now: Date = Date()) -> Validation {
        func string(_ name: String, limit: Int = 4000) -> String? {
            guard let value = (arguments[name] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return String(value.prefix(limit))
        }
        switch tool {
        case "open_app":
            let name = string("name", limit: 100) ?? ""
            guard let app = apps.resolve(name) else { return .refused("I couldn’t find an app called “\(name)”.") }
            return .step(.openApp(name: app.deletingPathExtension().lastPathComponent, path: app.path, bundle: AppCatalog.bundleID(app)))
        case "create_note":
            guard let body = Self.noteText(said: text, proposed: string("body")) else { return .skipped }
            return .step(.createNote(body: body))
        case "create_reminder":
            guard let title = string("title", limit: 500) else { return .skipped }
            // The due time is worked out from the transcript; the model is unreliable at date arithmetic.
            return .step(.createReminder(title: title, due: DueDate.resolve(text, now: now).map(DueDate.format)))
        case "run_shortcut":
            let name = string("name", limit: 200) ?? ""
            guard let match = shortcuts.first(where: { $0.lowercased() == name.lowercased() }) else {
                return .refused("There’s no shortcut called “\(name)”.")
            }
            return .step(.runShortcut(name: match, input: string("input")))
        case "web_search":
            guard let query = string("query", limit: 500) else { return .skipped }
            return .step(.openURL("https://www.google.com/search?q=" + Self.formEncode(query), label: "Search the web for \(query)"))
        case "open_url":
            var url = string("url", limit: 2000) ?? ""
            if url.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) == nil {
                url = "https://" + url.drop { $0 == "/" }
            }
            guard let components = URLComponents(string: url), ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
                  let host = components.host, host.contains("."), !host.contains(" ") else {
                return .refused("That doesn’t look like a website address.")
            }
            return .step(.openURL(url, label: "Open " + host + (components.port.map { ":\($0)" } ?? "")))
        case "set_volume":
            let value = arguments["percent"]
            let percent = (value as? Int) ?? (value as? Double).map { Int($0) } ?? (value as? String).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let percent else { return .skipped }
            return .step(.setVolume(max(0, min(100, percent))))
        default:
            return .skipped
        }
    }

    /// The note text to save, taken from what the user said wherever possible:
    /// 1. the words after a trigger phrase ("note saying…", "jot down…", "take a note that…"), or the X in "add X to my notes";
    /// 2. otherwise the model's text, if it appears in the transcript, copied from the transcript;
    /// 3. otherwise the model's text as a last resort.
    static func noteText(said: String, proposed: String?) -> String? {
        if let match = addToNote.firstMatch(in: said) ?? noteBody.firstMatch(in: said) {
            let body = match.group(1).trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { return body }
        }
        guard let proposed else { return nil }
        return transcriptSlice(matching: proposed, in: said) ?? proposed
    }

    /// Finds `phrase` in `text` as a run of whole words, ignoring case and punctuation,
    /// and returns the original wording from `text`.
    static func transcriptSlice(matching phrase: String, in text: String) -> String? {
        func words(_ string: String) -> [(word: String, range: Range<String.Index>)] {
            let pattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)*"#)
            return pattern.matches(in: string, range: NSRange(string.startIndex..., in: string)).map { match in
                let range = Range(match.range, in: string)!
                return (string[range].lowercased().replacingOccurrences(of: "’", with: "'"), range)
            }
        }
        let said = words(text), wanted = words(phrase).map(\.word)
        guard !wanted.isEmpty, wanted.count <= said.count else { return nil }
        for start in 0...(said.count - wanted.count) where said[start..<(start + wanted.count)].map(\.word) == wanted {
            return String(text[said[start].range.lowerBound..<said[start + wanted.count - 1].range.upperBound])
        }
        return nil
    }

    /// Encodes like an HTML form: letters, digits and -._~ stay, spaces become +.
    static func formEncode(_ text: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~ ")
        return (text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text).replacingOccurrences(of: " ", with: "+")
    }

    static func listShortcuts() async -> [String] {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            process.arguments = ["list"]
            let output = Pipe()
            process.standardOutput = output; process.standardError = Pipe()
            process.terminationHandler = { _ in
                let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                continuation.resume(returning: text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
            }
            do { try process.run() } catch { process.terminationHandler = nil; continuation.resume(returning: []) }
        }
    }

    private func ollamaChat(_ messages: [[String: Any]]) async throws -> [String: Any] {
        let tools = Self.tools.map { tool -> [String: Any] in
            ["type": "function", "function": ["name": tool.name, "description": tool.description,
                                               "parameters": ["type": "object", "properties": tool.properties, "required": tool.required]]]
        }
        let response = try await post("/api/chat", [
            "model": model, "messages": messages, "tools": tools, "stream": false, "think": false,
            "keep_alive": "30m", "options": ["temperature": 0, "num_ctx": 4096],
        ], timeout: 60)
        guard let message = response["message"] as? [String: Any] else { throw PlannerError("The local model returned no answer.") }
        return message
    }

    private func post(_ path: String, _ body: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        var request = URLRequest(url: server.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404, path == "/api/show" {
            throw PlannerError("Model \(model) is missing. Run: ollama pull \(model)")
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw PlannerError("Ollama returned an error: " + (String(data: data, encoding: .utf8) ?? "unknown"))
        }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
