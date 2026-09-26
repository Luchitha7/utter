"""Local LLM planner: turns a spoken command into validated tool steps via Ollama.

The model only proposes tool calls. Every call is checked here against a fixed tool
set and normalised into a step the Swift app knows how to execute; anything else is
dropped. Dictated text stays data and is never executed.
"""
import datetime
import json
import os
import plistlib
import re
import subprocess
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

OLLAMA = os.environ.get('UTTER_OLLAMA_URL', 'http://127.0.0.1:11434')
MODEL = os.environ.get('UTTER_MODEL', 'qwen3:4b-instruct')
MAX_STEPS = 6

APP_DIRS = [Path('/Applications'), Path('/Applications/Utilities'), Path('/System/Applications'),
            Path('/System/Applications/Utilities'), Path.home() / 'Applications']
EXTRA_APPS = [Path('/System/Library/CoreServices/Finder.app')]
ALIASES = {
    'chrome': 'google chrome', 'vs code': 'visual studio code', 'vscode': 'visual studio code',
    'code': 'visual studio code', 'settings': 'system settings', 'system preferences': 'system settings',
    'preferences': 'system settings', 'zoom': 'zoom.us', 'word': 'microsoft word', 'outlook': 'microsoft outlook',
    'itunes': 'music', 'apple music': 'music', 'facetime': 'facetime', 'app store': 'app store',
}

TOOLS = [
    ('open_app', 'Open or switch to an application installed on this Mac.',
     {'name': {'type': 'string', 'description': 'Application name as the user said it, e.g. "Spotify".'}}, ['name']),
    ('create_note', 'Create a note in Apple Notes.',
     {'body': {'type': 'string', 'description': "The note text, copied exactly from the user's words."}}, ['body']),
    ('create_reminder', 'Create a reminder in Apple Reminders, optionally with a due date and time.',
     {'title': {'type': 'string', 'description': "What to be reminded about, in the user's words."},
      'due': {'type': 'string', 'description': 'Optional local due time as YYYY-MM-DDTHH:MM.'}}, ['title']),
    ('run_shortcut', "Run one of the user's Apple Shortcuts by name.",
     {'name': {'type': 'string', 'description': 'Exact shortcut name from the available list.'},
      'input': {'type': 'string', 'description': 'Optional text to pass to the shortcut.'}}, ['name']),
    ('web_search', 'Search the web in the default browser.',
     {'query': {'type': 'string'}}, ['query']),
    ('open_url', 'Open a website in the default browser.',
     {'url': {'type': 'string', 'description': 'A website address such as youtube.com.'}}, ['url']),
    ('set_volume', 'Set the Mac output volume.',
     {'percent': {'type': 'integer', 'description': '0 to 100. Use 0 to mute.'}}, ['percent']),
]

SYSTEM = """You are the command interpreter for Utter, a macOS voice assistant.
The user's words come from speech recognition and may contain small transcription errors.
Turn the request into tool calls, in the order they should happen.

Rules:
- Only do what the user actually asked. If they negate or cancel ("don't", "never mind"), call no tools.
- If the user corrects themselves ("open Safari, actually Chrome"), act only on their final intent.
- For notes and reminders, copy the user's own words exactly. Do not rephrase, summarise or add anything.
- If the user asks to open an app, call open_app for it, even when a later step uses that app.
- Resolve relative dates and times ("tomorrow", "at 5") from the current local time you are given. "At 5" means 5:00 exactly, never the current minutes. A time with no am/pm means its next occurrence.
- If the request is a question, conversation, or something no tool can do, call no tools and reply to the user in one short friendly sentence. Never mention tools.
- Only use shortcut names from this list: {shortcuts}"""


def _norm(name):
    name = re.sub(r'[^a-z0-9. ]+', ' ', name.lower().replace('.app', ''))
    name = re.sub(r'\b(?:the|app|application)\b', ' ', name)
    return ' '.join(word.strip('.') for word in name.split()).strip()


def _info_plist(app):
    """A real app has an Info.plist; iPhone/iPad apps keep theirs inside WrappedBundle. Empty leftovers have none."""
    for plist in (app / 'Contents' / 'Info.plist', app / 'WrappedBundle' / 'Info.plist'):
        if plist.is_file():
            return plist
    return None


class Apps:
    """Installed applications, resolved from spoken names."""

    def __init__(self, dirs=APP_DIRS, extra=EXTRA_APPS):
        self.apps = {}
        for directory in dirs:
            try:
                paths = sorted(directory.glob('*.app'))
            except OSError:
                continue
            for path in paths:
                if _info_plist(path):
                    self.apps.setdefault(_norm(path.stem), path)
        for path in extra:
            if _info_plist(path):
                self.apps.setdefault(_norm(path.stem), path)

    def resolve(self, spoken):
        wanted = _norm(spoken)
        wanted = ALIASES.get(wanted, wanted)
        if not wanted:
            return None
        if wanted in self.apps:
            return self.apps[wanted]
        starts = [n for n in self.apps if n.startswith(wanted + ' ') or n.startswith(wanted)]
        if starts:
            return self.apps[min(starts, key=len)]
        words = [n for n in self.apps if re.search(r'\b' + re.escape(wanted) + r'\b', n)]
        return self.apps[min(words, key=len)] if words else None

    @staticmethod
    def bundle_id(path):
        try:
            with open(_info_plist(path), 'rb') as handle:
                return plistlib.load(handle).get('CFBundleIdentifier') or str(path)
        except (OSError, plistlib.InvalidFileException, ValueError):
            return str(path)


def list_shortcuts():
    try:
        out = subprocess.run(['/usr/bin/shortcuts', 'list'], capture_output=True, text=True, timeout=10).stdout
        return [line.strip() for line in out.splitlines() if line.strip()]
    except (OSError, subprocess.SubprocessError):
        return []


def _post(path, payload, timeout):
    request = urllib.request.Request(OLLAMA + path, data=json.dumps(payload).encode(),
                                     headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read())


class Planner:
    def __init__(self, apps=None, shortcuts=None, chat=None):
        self.apps = apps if apps is not None else Apps()
        self.shortcuts = shortcuts if shortcuts is not None else list_shortcuts()
        self.chat = chat or self._ollama_chat
        self.tools = [{'type': 'function', 'function': {
            'name': name, 'description': description,
            'parameters': {'type': 'object', 'properties': props, 'required': required}}}
            for name, description, props, required in TOOLS]
        self.system = SYSTEM.format(shortcuts=', '.join(f'"{s}"' for s in self.shortcuts) or '(none)')

    def _ollama_chat(self, messages):
        return _post('/api/chat', {
            'model': MODEL, 'messages': messages, 'tools': self.tools, 'stream': False, 'think': False,
            'keep_alive': '30m', 'options': {'temperature': 0, 'num_ctx': 4096},
        }, timeout=60)['message']

    def warm(self):
        try:
            _post('/api/show', {'model': MODEL}, timeout=10)
        except urllib.error.HTTPError:
            raise RuntimeError(f'Model {MODEL} is missing. Run: ollama pull {MODEL}')
        except OSError as error:
            raise RuntimeError(f'Ollama is not running. Start the Ollama app or run: brew services start ollama ({error})')
        self.plan('open notes')  # loads the model and caches the system prompt
        return f'{MODEL} via Ollama'

    def plan(self, text, now=None):
        now = now or datetime.datetime.now()
        message = self.chat([
            {'role': 'system', 'content': self.system},
            {'role': 'user', 'content': f'Current local time: {now:%A %Y-%m-%d %H:%M}.\nCommand: {text}'},
        ])
        steps, problems = [], []
        for call in (message.get('tool_calls') or [])[:MAX_STEPS]:
            function = call.get('function', {})
            arguments = function.get('arguments') or {}
            if isinstance(arguments, str):
                try:
                    arguments = json.loads(arguments)
                except ValueError:
                    arguments = {}
            step = self.validate(function.get('name'), arguments, text)
            if isinstance(step, str):
                problems.append(step)
            elif step and step['key'] not in {s['key'] for s in steps}:
                steps.append(step)
        # The model sometimes folds "open Notes" into create_note; keep the explicit open the user asked for.
        if any(s['tool'] == 'create_note' for s in steps) and OPEN_NOTES.search(text):
            notes = self.validate('open_app', {'name': 'Notes'}, text)
            if isinstance(notes, dict) and notes['key'] not in {s['key'] for s in steps}:
                steps.insert(0, notes)
        reply = re.sub(r'<think>.*?</think>', '', message.get('content') or '', flags=re.S).strip()
        if not steps and (not reply or re.search(r'\btools?\b|function', reply, re.I)):
            reply = 'OK, I won’t do anything.' if NEGATION.search(text) else FALLBACK_REPLY
        say = ' '.join(problems) or (reply[:200] if not steps else '')
        return {'steps': steps, 'say': say}

    def validate(self, tool, args, text):
        """Returns a step dict, None to skip silently, or a string describing why it was refused."""
        def text_arg(name, limit=4000):
            value = args.get(name)
            return value.strip()[:limit] if isinstance(value, str) and value.strip() else None

        if tool == 'open_app':
            name = text_arg('name', 100)
            path = self.apps.resolve(name) if name else None
            if not path:
                return f'I couldn’t find an app called “{name}”.'
            bundle = self.apps.bundle_id(path)
            return {'tool': 'open_app', 'app': path.stem, 'path': str(path), 'bundle': bundle,
                    'key': 'open:' + bundle, 'summary': f'Open {path.stem}'}
        if tool == 'create_note':
            body = verbatim_note(text) or text_arg('body')
            return body and {'tool': 'create_note', 'body': body, 'key': 'note', 'summary': f'Create note: {body[:60]}'}
        if tool == 'create_reminder':
            title = text_arg('title', 500)
            if not title:
                return None
            due = text_arg('due', 40)
            try:
                due = datetime.datetime.fromisoformat(due).strftime('%Y-%m-%dT%H:%M') if due else None
            except ValueError:
                due = None
            when = f' ({due.replace("T", " ")})' if due else ''
            return {'tool': 'create_reminder', 'title': title, 'due': due, 'key': 'reminder:' + title.lower(),
                    'summary': f'Remind me: {title}{when}'}
        if tool == 'run_shortcut':
            name = text_arg('name', 200) or ''
            match = next((s for s in self.shortcuts if s.lower() == name.lower()), None)
            if not match:
                return f'There’s no shortcut called “{name}”.'
            return {'tool': 'run_shortcut', 'name': match, 'input': text_arg('input'), 'key': 'shortcut:' + match,
                    'summary': f'Run shortcut {match}'}
        if tool == 'web_search':
            query = text_arg('query', 500)
            return query and {'tool': 'open_url', 'url': 'https://www.google.com/search?q=' + urllib.parse.quote_plus(query),
                              'key': 'search:' + query.lower(), 'summary': f'Search the web for {query}'}
        if tool == 'open_url':
            url = text_arg('url', 2000) or ''
            if not re.match(r'^https?://', url, re.I):
                url = 'https://' + url.lstrip('/')
            parsed = urllib.parse.urlparse(url)
            if parsed.scheme not in ('http', 'https') or '.' not in parsed.netloc or ' ' in parsed.netloc:
                return 'That doesn’t look like a website address.'
            return {'tool': 'open_url', 'url': url, 'key': 'url:' + url.lower(), 'summary': f'Open {parsed.netloc}'}
        if tool == 'set_volume':
            try:
                percent = max(0, min(100, int(args.get('percent'))))
            except (TypeError, ValueError):
                return None
            return {'tool': 'set_volume', 'percent': percent, 'key': 'volume', 'summary': f'Set volume to {percent}%'}
        return None


OPEN_NOTES = re.compile(r'\b(?:open|launch|start)\s+(?:the\s+)?notes\b', re.I)
NEGATION = re.compile(r'\b(?:don[’\']?t|do not|never mind|nevermind|cancel|stop)\b', re.I)
FALLBACK_REPLY = 'I can open apps and websites, search the web, make notes and reminders, run shortcuts and set the volume.'
NOTE_BODY = re.compile(r'\bnote\s+(?:saying|that says|with the text)\s+(.+)$', re.I | re.S)


def verbatim_note(text):
    """If the user used the explicit note phrasing, keep their exact words rather than the model's."""
    match = NOTE_BODY.search(text)
    return match.group(1).strip() if match else None
