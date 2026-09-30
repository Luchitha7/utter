import Foundation

// Minimal test runner: builds with only the Command Line Tools (no Xcode or XCTest needed).
// Run with ./scripts/test.sh

@MainActor var failures = 0
@MainActor var checks = 0

@MainActor func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    checks += 1
    if !condition() { failures += 1; print("  ✗ line \(line): \(message)") }
}

@MainActor func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String = "", line: Int = #line) {
    expect(actual == expected, "\(message) expected \(expected), got \(actual)", line: line)
}

@MainActor func test(_ name: String, _ body: () async throws -> Void) async {
    let before = failures
    do { try await body() } catch { failures += 1; print("  ✗ threw \(error)") }
    print(failures == before ? "✓ \(name)" : "✗ \(name)")
}

func call(_ tool: String, _ arguments: [String: Any]) -> [String: Any] {
    ["function": ["name": tool, "arguments": arguments]]
}

@main
struct CoreTests {
    @MainActor static func main() async {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("utter-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Notes", "Safari", "Google Chrome", "Spotify", "System Settings", "zoom.us", "Visual Studio Code"] {
            let contents = root.appendingPathComponent("\(name).app/Contents")
            try! FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            let plist = try! PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "test." + name.lowercased()], format: .xml, options: 0)
            try! plist.write(to: contents.appendingPathComponent("Info.plist"))
        }
        try! FileManager.default.createDirectory(at: root.appendingPathComponent("Broken.app"), withIntermediateDirectories: true)
        let apps = AppCatalog(directories: [root], extras: [])

        func planner(_ calls: [[String: Any]], content: String = "") -> Planner {
            Planner(model: "test", server: URL(string: "http://127.0.0.1:1")!, apps: apps, shortcuts: ["Water Eject", "Music Quiz"],
                    chat: { _ in ["content": content, "tool_calls": calls] })
        }

        // MARK: Grammar

        await test("grammar: partial command, then note") {
            expectEqual(Grammar.decide("open").action, .wait(reason: "Waiting for a supported command."))
            expectEqual(Grammar.decide("open notes and create").action, .open(app: "Notes", bundle: "com.apple.Notes", hasNote: false))
            let completed: Set<String> = ["open:com.apple.Notes"]
            let phrase = "Open Notes and create a note saying buy milk tomorrow"
            expectEqual(Grammar.decide(phrase, final: false, completed: completed).action, .wait(reason: "Finish listening to save the note."))
            expectEqual(Grammar.decide(phrase, final: true, completed: completed).action, .note(body: "buy milk tomorrow"))
            expectEqual(Grammar.decide(phrase, final: true, completed: completed.union(["note"])).action, .wait(reason: "Finish listening to save the note."))
        }

        await test("grammar: negation and conversation") {
            for text in ["don't open notes", "how do I open notes", "open notepad", "open notes actually safari", "open notes cancel", "open safari instead", "open notes do not"] {
                switch Grammar.decide(text).action {
                case .wait, .cancel: expect(true, text)
                default: expect(false, "should not act on: \(text)")
                }
            }
        }

        await test("grammar: literal note content") {
            let decision = Grammar.decide("create a note saying do not cancel the meeting", final: true, completed: ["open:com.apple.Notes"])
            expectEqual(decision.action, .note(body: "do not cancel the meeting"))
        }

        await test("grammar: exact application names") {
            expectEqual(Grammar.decide("please open the google chrome app").key, "open:com.google.Chrome")
            expectEqual(Grammar.decide("open noteskeeper").action, .wait(reason: "Waiting for a supported command."))
            expectEqual(Grammar.decide("open notes", completed: ["open:com.apple.Notes"]).key, nil)
        }

        await test("grammar: AI mode never acts on a half-finished sentence") {
            let partials = ["open", "open safari", "open safari actually", "open safari actually chrome"]
            for text in partials {
                if case .open = Grammar.decideWhileSpeaking(text, aiMode: true).action { expect(false, "opened early on: \(text)") }
            }
            expectEqual(Grammar.decideWhileSpeaking("open safari never mind", aiMode: true).action, .cancel)
            expectEqual(Grammar.decideWhileSpeaking("open safari", aiMode: false).key, "open:com.apple.Safari")
        }

        // MARK: App catalog

        await test("apps: spoken names resolve") {
            for (spoken, expected) in [("spotify", "Spotify"), ("the Chrome app", "Google Chrome"), ("settings", "System Settings"),
                                       ("zoom", "zoom.us"), ("VS Code", "Visual Studio Code"), ("Safari.", "Safari")] {
                expectEqual(apps.resolve(spoken)?.deletingPathExtension().lastPathComponent, expected, spoken)
            }
            expect(apps.resolve("photoshop") == nil, "unknown app")
            expect(apps.resolve("broken") == nil, "empty .app folder is skipped")
        }

        // MARK: Planner

        await test("planner: multi-step plan") {
            let plan = try await planner([call("open_app", ["name": "Notes"]), call("create_note", ["body": "buy milk"])]).plan("open notes and note buy milk")
            expectEqual(plan.steps.map(\.key), ["open:test.notes", "note"])
        }

        await test("planner: note keeps the user's exact words") {
            let plan = try await planner([call("create_note", ["body": "Buy milk."])]).plan("create a note saying buy milk and do not cancel")
            expectEqual(plan.steps, [.createNote(body: "buy milk and do not cancel")])
        }

        await test("planner: rejects unknown apps, shortcuts, tools and URLs") {
            let plan = try await planner([call("open_app", ["name": "Photoshop"]), call("run_shortcut", ["name": "Delete Everything"]),
                                          call("shell", ["command": "rm -rf ~"]), call("open_url", ["url": "javascript:alert(1)"])]).plan("x")
            expectEqual(plan.steps, [])
            expect(plan.say.contains("Photoshop") && plan.say.contains("Delete Everything"), plan.say)
        }

        await test("planner: shortcut, volume, URL and search") {
            let plan = try await planner([call("run_shortcut", ["name": "water eject"]), call("set_volume", ["percent": 150]),
                                          call("open_url", ["url": "youtube.com"]), call("web_search", ["query": "weather in colombo"])]).plan("x")
            expectEqual(plan.steps, [.runShortcut(name: "Water Eject", input: nil), .setVolume(100),
                                     .openURL("https://youtube.com", label: "Open youtube.com"),
                                     .openURL("https://www.google.com/search?q=weather+in+colombo", label: "Search the web for weather in colombo")])
        }

        await test("planner: reminder due dates are validated") {
            let good = try await planner([call("create_reminder", ["title": "call mum", "due": "2026-09-26T17:00"])]).plan("x")
            let bad = try await planner([call("create_reminder", ["title": "call mum", "due": "five pm"])]).plan("x")
            expectEqual(good.steps, [.createReminder(title: "call mum", due: "2026-09-26T17:00")])
            expectEqual(bad.steps, [.createReminder(title: "call mum", due: nil)])
        }

        await test("planner: replies without tools") {
            let plain = try await planner([], content: "<think></think>I can only control your Mac.").plan("what is the capital of France")
            expectEqual(plain, Plan(steps: [], say: "I can only control your Mac."))
            let robotic = planner([], content: "None of the tools are called.")
            expectEqual(try await robotic.plan("don't open spotify").say, "OK, I won’t do anything.")
            let fallback = try await robotic.plan("what is the capital of france").say
            expect(fallback.contains("reminders"), "fallback reply")
        }

        await test("planner: explicit open Notes is kept") {
            let plan = try await planner([call("create_note", ["body": "x"])]).plan("open notes and create a note saying buy milk")
            expectEqual(plan.steps.map(\.key), ["open:test.notes", "note"])
        }

        await test("planner: duplicate steps collapse") {
            let plan = try await planner([call("open_app", ["name": "Safari"]), call("open_app", ["name": "safari"])]).plan("x")
            expectEqual(plan.steps.count, 1)
        }

        await test("planner: string JSON arguments are accepted") {
            let plan = try await planner([["function": ["name": "set_volume", "arguments": "{\"percent\": \"30\"}"]]]).plan("x")
            expectEqual(plan.steps, [.setVolume(30)])
        }

        print(failures == 0 ? "\nAll \(checks) checks passed." : "\n\(failures) of \(checks) checks failed.")
        exit(failures == 0 ? 0 : 1)
    }
}
