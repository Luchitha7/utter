import Foundation

// Plans real spoken-style commands with the local Ollama model. Nothing is executed.
// Run with ./scripts/live-check.sh (needs Ollama running with the model pulled).

let cases: [(String, [String])] = [
    ("open safari", ["open_app"]),
    ("could you pull up chrome for me", ["open_app"]),
    ("open notes and create a note saying buy milk and bread tomorrow", ["open_app", "create_note"]),
    ("remind me to call mum at 5", ["create_reminder"]),
    ("remind me tomorrow morning at 9 to submit the report", ["create_reminder"]),
    ("search the web for pasta recipes", ["open_url"]),
    ("go to youtube.com", ["open_url"]),
    ("set the volume to 30 percent", ["set_volume"]),
    ("mute", ["set_volume"]),
    ("run my water eject shortcut", ["run_shortcut"]),
    ("open safari actually no open chrome", ["open_app"]),
    ("don't open safari", []),
    ("what is the capital of france", []),
    ("open whatsapp and then calculator", ["open_app", "open_app"]),
    ("jot down buy milk and eggs", ["create_note"]),
    ("add call the plumber to my notes", ["create_note"]),
]

func tool(_ step: Step) -> String {
    switch step {
    case .openApp: return "open_app"
    case .createNote: return "create_note"
    case .createReminder: return "create_reminder"
    case .runShortcut: return "run_shortcut"
    case .openURL: return "open_url"
    case .setVolume: return "set_volume"
    }
}

@main
struct LivePlanner {
    @MainActor static func main() async {
        let environment = ProcessInfo.processInfo.environment
        let planner = Planner(model: environment["UTTER_MODEL"] ?? "qwen3:4b-instruct",
                              server: URL(string: environment["UTTER_OLLAMA_URL"] ?? "http://127.0.0.1:11434")!)
        planner.shortcuts = await Planner.listShortcuts()
        var started = Date()
        do { print("warm-up:", try await planner.warm(), String(format: "%.1fs", Date().timeIntervalSince(started))) }
        catch { print(error.localizedDescription); exit(1) }
        var passed = 0
        for (text, expected) in cases {
            started = Date()
            guard let plan = try? await planner.plan(text) else { print("ERROR  \(text)"); continue }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let ok = plan.steps.map(tool) == expected
            passed += ok ? 1 : 0
            let detail = plan.steps.isEmpty ? plan.say : plan.steps.map(\.summary).joined(separator: "; ")
            print("\(ok ? "PASS" : "FAIL") \(String(format: "%5d", ms)) ms  \(text.padding(toLength: 64, withPad: " ", startingAt: 0)) -> \(detail)")
        }
        print("\(passed)/\(cases.count) passed")
        exit(passed == cases.count ? 0 : 1)
    }
}
