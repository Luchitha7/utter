<p align="center">
  <img src="assets/AppIcon.png" alt="Utter icon" width="128" />
</p>

<h1 align="center">Utter</h1>

<p align="center"><b>Private voice control for your Mac.</b><br/>
Say what you want in plain words. A small AI model running on your Mac turns it into actions.</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black" />
  <img alt="Runs locally" src="https://img.shields.io/badge/AI-runs%20locally-8A5CFF" />
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-green" />
</p>

---

Press **⌘⇧Space**, speak, and Utter does it:

| You say | Utter does |
|---|---|
| “Could you pull up Chrome” | Opens any installed app |
| “Open WhatsApp and then Calculator” | Runs several steps in order |
| “Open Notes and create a note saying buy milk and bread” | Creates the note, word for word |
| “Remind me to call mum at 5” | Adds a reminder for 5:00 pm with an alert |
| “Run my Water Eject shortcut” | Runs one of your Apple Shortcuts |
| “Search for pasta recipes” · “Go to youtube.com” | Opens it in your browser |
| “Set volume to 30” · “Mute” | Changes the volume |
| “Open Safari… actually Chrome” | Acts on what you meant |

Everything runs **on your Mac**. The language model is served by [Ollama](https://ollama.com), and speech recognition uses Apple's on-device recognizer when your Mac supports it. There is no account, no API key and no cloud service.

## Requirements

- macOS 14 Sonoma or later, Apple Silicon recommended
- Xcode Command Line Tools: `xcode-select --install`
- [Ollama](https://ollama.com) with the `qwen3:4b-instruct` model (about 2.5 GB)

## Install

```sh
brew install ollama
brew services start ollama
ollama pull qwen3:4b-instruct

git clone https://github.com/Luchitha7/utter.git
cd utter
./scripts/build.sh
open build/Utter.app
```

The build is ad-hoc signed for your own Mac and isn't notarized. The app runs its Python backend from the folder you cloned, so keep the folder in place and rebuild if you move it. Utter uses the Python that ships with the Command Line Tools and needs no extra packages.

On first use, macOS asks for permission to use the **microphone** and **speech recognition**. It asks again the first time Utter creates a note (**Notes automation**) or a reminder (**Reminders**).

## Use

1. Press **⌘⇧Space** from any app, or click **Start listening**.
2. Say a command.
3. Press **⌘⇧Space** again, or click **Finish command**.

Simple commands such as “open Safari” can start while you're still speaking. Everything else runs when you finish.

You can also type a command and press **Run**. **Preview only** shows the planned steps without doing anything. **Exact commands** skips the AI and accepts only fixed phrases (“open Safari”, “create a note saying …”), which is useful when Ollama isn't running.

## How it works

```
 ⌘⇧Space ─▶ microphone ─▶ Apple Speech ─▶ transcript
                                              │  JSON over a private pipe
                                              ▼
                                    backend/engine.py
                                              │
                           ┌──────────────────┴──────────────────┐
                    while speaking                         when you finish
                 fixed phrases only                 backend/planner.py ─▶ Ollama
                 (early “open X”)                   (qwen3:4b-instruct, tool calling)
                           └──────────────────┬──────────────────┘
                                              ▼
                                  validated list of steps
                                              ▼
            Sources/Utter.swift runs each step with a native API:
            NSWorkspace · AppleScript (Notes) · EventKit (Reminders)
            · shortcuts CLI · osascript (volume)
```

- **The Swift app** ([`Sources/Utter.swift`](Sources/Utter.swift)) handles the hotkey, microphone, speech recognition, the window and menu-bar icon, and the actions themselves.
- **The Python backend** ([`backend/`](backend/)) reads JSON requests from the app. It uses only the Python standard library.
- **The planner** ([`backend/planner.py`](backend/planner.py)) asks the model to choose from seven fixed tools, then checks every call before anything runs.

### Safety

- The model can only pick from a fixed set of actions. It can't run shell commands, delete files or send messages.
- Apps must actually be installed, shortcuts must exist by exact name, and URLs must be `http` or `https`. Anything else is refused with a message.
- Dictated note text is passed as data, never inserted into scripts, and kept exactly as you said it.
- Cancel stops pending steps. It doesn't undo an app that's already open or a note that's already been created.

## Development

```sh
python3 -m unittest discover -s tests -v   # fast unit tests, no model needed
python3 tests/live_planner.py              # plans real commands with Ollama; executes nothing
./scripts/build.sh                         # builds build/Utter.app
```

Logs are written to `~/Library/Logs/Utter/engine.log`. To use a different Ollama model or server, set `UTTER_MODEL` or `UTTER_OLLAMA_URL`.

### Adding a tool

1. Describe it in `TOOLS` and validate its arguments in `Planner.validate` ([`backend/planner.py`](backend/planner.py)).
2. Carry it out in `perform(_:)` ([`Sources/Utter.swift`](Sources/Utter.swift)).
3. Add a unit test in [`tests/test_planner.py`](tests/test_planner.py) and a spoken example in [`tests/live_planner.py`](tests/live_planner.py).

## Limitations

- English (US) speech only.
- No wake word. You start listening with the hotkey or button.
- An app that opens while you're still speaking stays open even if you then correct yourself.
- Only the actions listed above are supported. Utter doesn't understand what's on screen.

## License

[MIT](LICENSE)
