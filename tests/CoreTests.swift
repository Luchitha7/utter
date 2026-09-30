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

        // MARK: Due dates

        await test("due dates: worked out in code from what was said") {
            func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
                Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
            }
            let evening = at(30, 19, 42), morning = at(30, 8, 10), lateNight = at(30, 23, 55)  // Wednesday
            let cases: [(String, Date, String?)] = [
                ("remind me to call mum at 5", evening, "2026-10-01T05:00"),
                ("remind me to call mum at 5", morning, "2026-09-30T17:00"),
                ("remind me to call mum at 5", lateNight, "2026-10-01T05:00"),
                ("remind me at 9", morning, "2026-09-30T09:00"),
                ("remind me tomorrow morning at 9 to submit the report", evening, "2026-10-01T09:00"),
                ("remind me tomorrow at 9", lateNight, "2026-10-01T09:00"),
                ("remind me tomorrow at 5", morning, "2026-10-01T17:00"),
                ("remind me at 5pm to stretch", evening, "2026-10-01T17:00"),
                ("remind me at 9 pm to stretch", evening, "2026-09-30T21:00"),
                ("remind me at 7:15 am", evening, "2026-10-01T07:15"),
                ("remind me at 21:30 to call dad", evening, "2026-09-30T21:30"),
                ("remind me at noon tomorrow", evening, "2026-10-01T12:00"),
                ("remind me this evening at 8", evening, "2026-09-30T20:00"),
                ("remind me tonight to lock the door", evening, "2026-09-30T20:00"),
                ("remind me on friday at 3 to pay rent", evening, "2026-10-02T15:00"),
                ("remind me next monday to call the bank", evening, "2026-10-05T09:00"),
                ("remind me in 20 minutes to check the oven", evening, "2026-09-30T20:02"),
                ("remind me in an hour", evening, "2026-09-30T20:42"),
                ("remind me in half an hour", evening, "2026-09-30T20:12"),
                ("remind me in 10 minutes", lateNight, "2026-10-01T00:05"),
                ("remind me in two hours to move the car", evening, "2026-09-30T21:42"),
                ("remind me to buy milk", evening, nil),
            ]
            for (said, now, expected) in cases {
                expectEqual(DueDate.resolve(said, now: now).map(DueDate.format), expected, "\(said) @ \(DueDate.format(now))")
            }
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

        await test("planner: reminder time comes from the transcript, not the model") {
            let now = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 19, minute: 42))!
            let wrong = try await planner([call("create_reminder", ["title": "call mum", "due": "2026-09-30T20:00"])]).plan("remind me to call mum at 5", now: now)
            expectEqual(wrong.steps, [.createReminder(title: "call mum", due: "2026-10-01T05:00")])
            let none = try await planner([call("create_reminder", ["title": "buy milk", "due": "2026-09-30T20:00"])]).plan("remind me to buy milk", now: now)
            expectEqual(none.steps, [.createReminder(title: "buy milk", due: nil)])
        }

        await test("planner: replies without tools") {
            let plain = try await planner([], content: "<think></think>I can only control your Mac.").plan("what is the capital of France")
            expectEqual(plain, Plan(steps: [], say: "I can only control your Mac."))
            let robotic = planner([], content: "None of the tools are called.")
            expectEqual(try await robotic.plan("don't open spotify").say, "OK, I won’t do anything.")
            let fallback = try await robotic.plan("what is the capital of france").say
            expect(fallback.contains("reminders"), "fallback reply")
        }

        await test("planner: note text comes from the transcript, not the model") {
            let cases: [(said: String, proposed: String, saved: String)] = [
                ("jot down buy milk and eggs", "Buy milk and eggs.", "buy milk and eggs"),
                ("open notes and write down call the dentist", "Call dentist", "call the dentist"),
                ("take a note that the meeting moved to 3", "Meeting moved to 3pm.", "the meeting moved to 3"),
                ("make a note: pay rent on Friday", "Pay rent Friday", "pay rent on Friday"),
                ("add buy oat milk to my shopping note", "Buy oat milk.", "buy oat milk"),
                ("add call the plumber to my notes", "add call the plumber to my notes", "call the plumber"),
                ("please add pick up the parcel to the note", "Pick up parcel", "pick up the parcel"),
                ("put Sam's birthday is on Friday in my notes", "Sam’s birthday is on Friday", "Sam's birthday is on Friday"),
            ]
            for (said, proposed, saved) in cases {
                let plan = try await planner([call("create_note", ["body": proposed])]).plan(said)
                expectEqual(plan.steps.filter { $0.key == "note" }, [.createNote(body: saved)], said)
            }
        }

        await test("planner: a reworded note with no trigger phrase keeps the model's text") {
            let plan = try await planner([call("create_note", ["body": "Sam birthday Friday"])]).plan("remember in notes that it's Sam's birthday this Friday")
            expectEqual(plan.steps, [.createNote(body: "Sam birthday Friday")])
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
