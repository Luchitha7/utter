import AppKit
import SwiftUI
import AVFoundation
import Speech
import Carbon
import EventKit

struct PlanError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct Activity: Identifiable {
    let id = UUID()
    let text: String
    let time = Date()
}

@MainActor
final class Assistant: ObservableObject {
    @Published var listening = false
    @Published var transcript = ""
    @Published var status = "Ready when you are"
    @Published var engine = "ai"
    @Published var modelStatus = "Starting local AI…"
    @Published var ready = false
    @Published var latency = "—"
    @Published var speechInfo = "Speech recognition: checking availability"
    @Published var activities: [Activity] = []
    @Published var typedCommand = ""
    @Published var busy = false
    @Published var dryRun = false
    private var worker: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorLog: FileHandle?
    private var responseBuffer = Data()
    private var recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audio = AVAudioEngine()
    private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var speechTask: SFSpeechRecognitionTask?
    private var tapInstalled = false
    private var debounce: Task<Void, Never>?
    private var session = UUID().uuidString
    private var revision = 0
    private var inFlight: String?
    private var pending: [String: Any]?
    private var completed: Set<String> = []
    private var ending = false
    private var starting = false
    private var isFinishing = false
    private var finishTask: Task<Void, Never>?
    private var workerStopped = false

    init() {
        speechInfo = recognizer?.supportsOnDeviceRecognition == true
            ? "Speech stays on this Mac · English (US)"
            : "Speech uses Apple’s recognition service · English (US)"
        startWorker()
    }

    func log(_ text: String) {
        activities.insert(Activity(text: text), at: 0)
        activities = Array(activities.prefix(12))
    }

    func startWorker() {
        let resources = Bundle.main.resourceURL!
        guard let root = try? String(contentsOf: resources.appendingPathComponent("workspace.txt"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
            status = "Missing workspace configuration"; return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", root + "/backend/engine.py"]
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        let incoming = Pipe(), outgoing = Pipe()
        process.standardInput = incoming
        process.standardOutput = outgoing
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Utter")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let logURL = logs.appendingPathComponent("engine.log")
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        errorLog = try? FileHandle(forWritingTo: logURL)
        _ = try? errorLog?.seekToEnd()
        process.standardError = errorLog ?? FileHandle.standardError
        input = incoming.fileHandleForWriting
        output = outgoing.fileHandleForReading
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            guard let self else { return }
            Task { @MainActor in self.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                guard !self.workerStopped else { return }
                self.ready = false; self.busy = false; self.inFlight = nil
                self.modelStatus = "Engine stopped — reopen Utter"
                self.status = "Local engine stopped. See ~/Library/Logs/Utter/engine.log"
            }
        }
        do {
            try process.run(); worker = process
            send(["type": "load"])
        } catch { status = error.localizedDescription; modelStatus = "Engine unavailable" }
    }

    private func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let input else { return }
        do { try input.write(contentsOf: data + Data([10])) }
        catch { status = "Could not reach the local engine"; busy = false }
    }

    private func receive(_ data: Data) {
        responseBuffer.append(data)
        while let newline = responseBuffer.firstIndex(of: 10) {
            let line = responseBuffer[..<newline]
            responseBuffer.removeSubrange(...newline)
            guard let result = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            handle(result)
        }
    }

    private func handle(_ result: [String: Any]) {
        if result["type"] as? String == "ready" {
            ready = true; modelStatus = "\(result["device"] as? String ?? "Local AI") · on this Mac"
            log("Local AI ready. Nothing leaves your Mac.")
            return
        }
        if result["type"] as? String == "error" {
            let message = result["message"] as? String ?? "Unknown error"
            log("Engine: " + message)
            if result["id"] as? String == nil { modelStatus = "AI unavailable · using Exact commands"; engine = "exact"; ready = true }
        }
        guard let id = result["id"] as? String, id == inFlight else { return }
        inFlight = nil; busy = false
        defer { pump() }
        guard id.hasPrefix(session + ":") else { return }
        guard let sourceText = result["text"] as? String,
              transcript.lowercased().hasPrefix(sourceText.lowercased()) else { return }
        let action = result["action"] as? String ?? "wait"
        if action == "cancel" { cancel(); return }
        if action == "plan" { runPlan(result); return }
        // A correction or cancellation in a newer partial transcript invalidates old decisions.
        let lower = transcript.lowercased()
        let bodyStart = lower.range(of: "\\s(?:saying|that says|with the text)\\s", options: .regularExpression)
        let commandPart = bodyStart.map { String(lower[..<$0.lowerBound]) } ?? lower
        if commandPart.range(of: "\\b(actually|instead|cancel|never mind|don't|do not|wait)\\b", options: .regularExpression) != nil {
            status = "Correction heard. Start a fresh command."; return
        }
        latency = "\(result["ms"] as? Int ?? 0) ms"
        guard let key = result["key"] as? String, !completed.contains(key), action != "wait" else {
            if let reason = result["reason"] as? String { status = reason }
            return
        }
        completed.insert(key)
        if dryRun {
            log("Preview: \(action == "note" ? "create note" : "open " + (result["app"] as? String ?? "app"))")
            status = "Preview only — nothing changed"
            if ending && engine != "ai" && action == "open" && result["has_note"] as? Bool == true { enqueue(final: true) }
            return
        }
        if action == "open", let bundle = result["bundle"] as? String {
            let allowed = ["com.apple.Notes", "com.apple.Safari", "com.google.Chrome", "com.apple.finder", "com.apple.Music", "com.spotify.client"]
            guard allowed.contains(bundle), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else {
                status = "That app isn’t installed"; log(status); return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            let appName = result["app"] as? String ?? "app"
            let actionSession = session
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
                Task { @MainActor in
                    guard let self, self.session == actionSession else { return }
                    if let error { self.status = error.localizedDescription; self.log(self.status) }
                    else {
                        self.status = "Opened \(appName)"; self.log(self.status)
                        if self.ending && self.engine != "ai" && result["has_note"] as? Bool == true { self.enqueue(final: true) }
                    }
                }
            }
        } else if action == "note", let body = result["body"] as? String, result["final"] as? Bool == true {
            createNote(body)
        }
    }

    private func createNote(_ body: String) {
        let actionSession = session
        status = "Creating note…"
        Task { @MainActor in
            do {
                try await writeNote(body)
                guard session == actionSession else { return }
                status = "Note created"; log("Created note: " + String(body.prefix(80)))
            } catch {
                guard session == actionSession else { return }
                status = error.localizedDescription; log(status)
            }
        }
    }

    private func writeNote(_ body: String) async throws {
        let script = Bundle.main.resourceURL!.appendingPathComponent("create-note.applescript").path
        // Text is a positional argument, never interpolated into AppleScript or shell code.
        let html = body.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\n", with: "<br>")
        try await runTool("/usr/bin/osascript", [script, html], failure: "Could not create note. Allow Notes automation in System Settings.")
    }

    /// Runs a fixed executable with an argument array (no shell), throwing with `failure` on a non-zero exit.
    private func runTool(_ path: String, _ arguments: [String], failure: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let errors = Pipe(); process.standardError = errors; process.standardOutput = Pipe()
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { process.terminationHandler = nil; continuation.resume(throwing: error) }
        }
        if status != 0 {
            let detail = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw PlanError(failure + (detail.isEmpty ? "" : " " + detail.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    private func runPlan(_ result: [String: Any]) {
        latency = "\(result["ms"] as? Int ?? 0) ms"
        let say = result["say"] as? String ?? ""
        let steps = (result["steps"] as? [[String: Any]] ?? []).filter { !completed.contains($0["key"] as? String ?? "") }
        guard !steps.isEmpty else {
            status = say.isEmpty ? "Done" : say
            if !say.isEmpty { log(say) }
            return
        }
        for step in steps { if let key = step["key"] as? String { completed.insert(key) } }
        if dryRun {
            for step in steps { log("Preview: " + (step["summary"] as? String ?? "step")) }
            status = "Preview only — nothing changed"; return
        }
        let actionSession = session
        busy = true
        Task { @MainActor in
            defer { if session == actionSession { busy = inFlight != nil } }
            for step in steps {
                guard session == actionSession else { return }
                status = (step["summary"] as? String ?? "Working") + "…"
                do {
                    try await perform(step)
                    log(step["summary"] as? String ?? "Done")
                } catch {
                    status = error.localizedDescription; log(status); return
                }
            }
            status = say.isEmpty ? "Done" : say
            if !say.isEmpty { log(say) }
        }
    }

    /// Executes one validated step. Each tool maps to a fixed native action; nothing is evaluated as code.
    private func perform(_ step: [String: Any]) async throws {
        switch step["tool"] as? String {
        case "open_app":
            guard let path = step["path"] as? String, path.hasSuffix(".app"), FileManager.default.fileExists(atPath: path) else {
                throw PlanError("That app isn’t installed")
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: configuration)
        case "create_note":
            guard let body = step["body"] as? String, !body.isEmpty else { throw PlanError("The note was empty") }
            try await writeNote(body)
        case "create_reminder":
            guard let title = step["title"] as? String, !title.isEmpty else { throw PlanError("The reminder was empty") }
            try await createReminder(title, due: step["due"] as? String)
        case "run_shortcut":
            guard let name = step["name"] as? String else { throw PlanError("Missing shortcut name") }
            var arguments = ["run", name]
            var inputFile: URL?
            if let input = step["input"] as? String, !input.isEmpty {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent("utter-\(UUID().uuidString).txt")
                try input.write(to: file, atomically: true, encoding: .utf8)
                arguments += ["--input-path", file.path]; inputFile = file
            }
            defer { if let inputFile { try? FileManager.default.removeItem(at: inputFile) } }
            try await runTool("/usr/bin/shortcuts", arguments, failure: "The shortcut “\(name)” failed.")
        case "open_url":
            guard let text = step["url"] as? String, let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw PlanError("That doesn’t look like a website address")
            }
            guard NSWorkspace.shared.open(url) else { throw PlanError("Could not open \(text)") }
        case "set_volume":
            guard let percent = step["percent"] as? Int, (0...100).contains(percent) else { throw PlanError("Invalid volume") }
            try await runTool("/usr/bin/osascript", ["-e", "on run argv", "-e", "set volume output volume (item 1 of argv as integer)", "-e", "end run", String(percent)],
                              failure: "Could not change the volume.")
        default:
            throw PlanError("Unsupported step")
        }
    }

    private func createReminder(_ title: String, due: String?) async throws {
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else {
            throw PlanError("Allow Utter to use Reminders in System Settings → Privacy & Security.")
        }
        guard let calendar = store.defaultCalendarForNewReminders() else { throw PlanError("No Reminders list found") }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = calendar
        if let due {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
            if let date = formatter.date(from: due) {
                reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                reminder.addAlarm(EKAlarm(absoluteDate: date))
            }
        }
        try store.save(reminder, commit: true)
    }

    private func enqueue(final: Bool) {
        guard !transcript.isEmpty else { return }
        revision += 1
        pending = ["id": session + ":" + String(revision), "text": transcript, "final": final,
                   "completed": Array(completed), "engine": engine]
        pump()
    }

    private func pump() {
        guard inFlight == nil, let request = pending else { return }
        pending = nil; inFlight = request["id"] as? String; busy = true; send(request)
    }

    func toggle() {
        if listening { finish() } else { Task { await begin() } }
    }

    func begin() async {
        guard !listening, !starting, ready else { return }
        starting = true
        defer { starting = false }
        let microphone = await AVCaptureDevice.requestAccess(for: .audio)
        guard microphone else { status = "Allow Utter microphone access in System Settings → Privacy & Security."; return }
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard authorization == .authorized else { status = "Allow Utter speech recognition in System Settings → Privacy & Security."; return }
        guard let recognizer, recognizer.isAvailable else { status = "Speech recognition isn’t available right now."; return }
        resetSession()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        request.contextualStrings = ["Notes", "Safari", "Spotify", "Chrome", "Finder", "create a note saying"]
        speechRequest = request
        let node = audio.inputNode
        let format = node.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { status = "No working microphone found."; return }
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in request.append(buffer) }
        tapInstalled = true
        let speechSession = session
        speechTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.session == speechSession, self.listening || self.isFinishing else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if self.isFinishing {
                        if result.isFinal { self.completeSpeech() }
                        return
                    }
                    self.status = "Listening…"
                    self.debounce?.cancel()
                    if result.isFinal { self.finish(); self.completeSpeech() }
                    else {
                        self.debounce = Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 180_000_000)
                            guard !Task.isCancelled, self.listening else { return }
                            self.enqueue(final: false)
                        }
                    }
                }
                if let error {
                    if self.isFinishing { self.completeSpeech() }
                    else if self.listening { self.cancel(); self.status = error.localizedDescription }
                }
            }
        }
        do { audio.prepare(); try audio.start(); listening = true; status = "Listening… speak a command" }
        catch { stopAudio(); status = error.localizedDescription }
    }

    private func stopAudio() {
        audio.stop()
        if tapInstalled { audio.inputNode.removeTap(onBus: 0); tapInstalled = false }
        speechRequest?.endAudio(); speechTask?.cancel()
        speechRequest = nil; speechTask = nil; listening = false
    }

    private func resetSession() {
        debounce?.cancel(); finishTask?.cancel(); isFinishing = false; stopAudio(); session = UUID().uuidString
        pending = nil; completed = []; transcript = ""; ending = false
    }

    func finish() {
        guard listening else { return }
        debounce?.cancel(); listening = false; isFinishing = true
        audio.stop()
        if tapInstalled { audio.inputNode.removeTap(onBus: 0); tapInstalled = false }
        speechRequest?.endAudio()
        status = "Finishing your command…"
        finishTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self.completeSpeech()
        }
    }

    private func completeSpeech() {
        guard isFinishing else { return }
        isFinishing = false; finishTask?.cancel(); stopAudio(); ending = true
        status = transcript.isEmpty ? "No speech heard" : "Finishing your command…"
        enqueue(final: true)
    }

    func cancel() {
        resetSession(); status = "Cancelled pending actions"; log(status)
    }

    func runTyped() {
        guard ready, !typedCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = typedCommand
        resetSession(); transcript = text; ending = true; status = "Checking command…"; enqueue(final: true)
    }

    func shutdown() {
        workerStopped = true; stopAudio(); output?.readabilityHandler = nil
        try? input?.close(); worker?.terminate()
    }
}

struct MainView: View {
    @ObservedObject var assistant: Assistant
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("UTTER").font(.system(size: 11, weight: .bold, design: .monospaced)).tracking(3).foregroundStyle(.secondary)
                    Text("Say it. Start it.").font(.system(size: 32, weight: .semibold, design: .rounded))
                }
                Spacer()
                Label(assistant.ready ? "On your Mac" : "Warming up", systemImage: assistant.ready ? "desktopcomputer" : "hourglass")
                    .font(.caption).padding(9).background(.white.opacity(0.07), in: Capsule())
            }
            VStack(alignment: .leading, spacing: 15) {
                HStack {
                    Circle().fill(assistant.listening ? Color.mint : Color.gray).frame(width: 8, height: 8)
                    Text(assistant.status).font(.system(size: 13, weight: .medium)).lineLimit(3)
                    Spacer()
                    if assistant.busy { ProgressView().controlSize(.small) }
                }
                Text(assistant.transcript.isEmpty ? "“Open Notes and create a note saying buy milk tomorrow.”" : assistant.transcript)
                    .font(.system(size: 22, weight: .medium, design: .rounded))
                    .foregroundStyle(assistant.transcript.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, minHeight: 105, alignment: .topLeading)
                    .textSelection(.enabled)
                HStack {
                    Button { assistant.toggle() } label: {
                        Label(assistant.listening ? "Finish command" : "Start listening", systemImage: assistant.listening ? "stop.fill" : "mic.fill")
                            .font(.system(size: 14, weight: .semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent).tint(.mint).disabled(!assistant.ready)
                    Button("Cancel") { assistant.cancel() }.buttonStyle(.plain).foregroundStyle(.secondary)
                    Spacer()
                    Text("⌘ ⇧ Space").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                }
            }.padding(22).background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 20))
            HStack {
                Picker("Decision engine", selection: $assistant.engine) {
                    Text("AI · Qwen, on this Mac").tag("ai")
                    Text("Exact commands").tag("exact")
                }.frame(width: 290).disabled(assistant.listening || assistant.busy)
                Spacer()
                Toggle("Preview only", isOn: $assistant.dryRun).toggleStyle(.checkbox).disabled(assistant.listening || assistant.busy)
            }
            HStack(spacing: 8) {
                TextField("Or type a command to test", text: $assistant.typedCommand).textFieldStyle(.roundedBorder).onSubmit { assistant.runTyped() }
                Button("Run") { assistant.runTyped() }.disabled(!assistant.ready || assistant.listening)
            }
            HStack {
                Text(assistant.modelStatus)
                Spacer()
                Text("Last decision: \(assistant.latency)")
            }.font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("RECENT ACTIVITY").font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2).foregroundStyle(.secondary)
                if assistant.activities.isEmpty { Text("Actions appear here as you speak.").font(.caption).foregroundStyle(.secondary) }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(assistant.activities) { activity in
                            HStack(alignment: .top) {
                                Image(systemName: "arrow.up.right").foregroundStyle(.mint)
                                Text(activity.text).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                                Text(activity.time, style: .time).foregroundStyle(.tertiary)
                            }.font(.system(size: 12))
                        }
                    }
                }.frame(height: 85)
            }
            Text("\(assistant.speechInfo)\nTry “open Spotify”, “remind me to call mum at 5”, “search the web for pasta recipes” or “set volume to 30”.")
                .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
        }
        .padding(30).frame(width: 660).background(Color(red: 0.055, green: 0.075, blue: 0.09))
        .preferredColorScheme(.dark)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var assistant: Assistant!
    var window: NSWindow!
    var statusItem: NSStatusItem!
    var hotKey: EventHotKeyRef?
    func applicationDidFinishLaunching(_ notification: Notification) {
        assistant = Assistant()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 680), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Utter"; window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: MainView(assistant: assistant))
        window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Utter")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Utter", action: #selector(show), keyEquivalent: "")
        menu.addItem(withTitle: "Start / finish listening", action: #selector(toggle), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit Utter", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Utter")
        let showItem = NSMenuItem(title: "Show Utter", action: #selector(show), keyEquivalent: "0")
        showItem.target = self
        applicationMenu.addItem(showItem)
        applicationMenu.addItem(NSMenuItem.separator())
        let quitItem = NSMenuItem(title: "Quit Utter", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        applicationMenu.addItem(quitItem)
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        NSApp.mainMenu = mainMenu
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, pointer in
            guard let pointer else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(pointer).takeUnretainedValue()
            Task { @MainActor in delegate.toggle() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), nil)
        let code = RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | shiftKey), EventHotKeyID(signature: 0x55545452, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if code != noErr { assistant.log("Global shortcut is unavailable. Use the microphone button.") }
        show()
    }
    @objc func show() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func toggle() { if !assistant.listening { show() }; assistant.toggle() }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { assistant.shutdown(); if let hotKey { UnregisterEventHotKey(hotKey) } }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct UtterMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
