"""Local-only decision worker. stdin/stdout are a private JSON-lines pipe."""
import json
import re
import sys
import time

APPS = {
    'notes': ('Notes', 'com.apple.Notes'),
    'safari': ('Safari', 'com.apple.Safari'),
    'chrome': ('Google Chrome', 'com.google.Chrome'),
    'google chrome': ('Google Chrome', 'com.google.Chrome'),
    'finder': ('Finder', 'com.apple.finder'),
    'music': ('Music', 'com.apple.Music'),
    'spotify': ('Spotify', 'com.spotify.client'),
}
OPEN = re.compile(r'^(?:please\s+)?(?:open|launch|start)\s+(?:the\s+)?(google chrome|chrome|notes|safari|finder|music|spotify)(?:\s+app)?(?=$|[\s,.!?])', re.I)
NOTE = re.compile(r'^(?:(?:please\s+)?(?:open|launch|start)\s+(?:the\s+)?notes(?:\s+app)?\s+(?:and|then)\s+)?(?:please\s+)?(?:create|make|write)\s+(?:a\s+)?(?:new\s+)?note\s+(?:saying|that says|with the text)\s+(.+)$', re.I | re.S)
CANCEL = re.compile(r'\b(?:cancel|never mind|nevermind|stop listening)\b', re.I)
CORRECTION = re.compile(r'\b(?:actually|instead|don[’\']t|do not|wait)\b', re.I)


def candidate(text, final=False, completed=()):
    """Bounded command grammar; free-form dictation is data, never executable code."""
    text = text.strip()
    if len(text) > 8000:
        return {'action': 'wait', 'reason': 'Command is too long.'}
    # An explicit cancel alone always cancels. Words inside dictated note content are literal.
    note = NOTE.match(text)
    command_part = text[:note.start(1)] if note else text
    if CANCEL.search(command_part):
        return {'action': 'cancel', 'reason': 'Cancelled.'}
    if CORRECTION.search(command_part):
        return {'action': 'wait', 'reason': 'Correction heard. Start a fresh command.'}
    opened = OPEN.match(text)
    target = APPS[opened.group(1).lower()] if opened else (APPS['notes'] if note else None)
    if target:
        label, bundle = target
        key = 'open:' + bundle
        if key not in completed:
            return {'action': 'open', 'app': label, 'bundle': bundle, 'key': key, 'has_note': note is not None}
    if note and final:
        body = note.group(1).strip()
        if body and 'note' not in completed:
            return {'action': 'note', 'body': body, 'key': 'note'}
    return {'action': 'wait', 'reason': 'Finish listening to save the note.' if note else 'Waiting for a supported command.'}


class Engine:
    def __init__(self):
        self.planner = None

    def load(self):
        """Warms up the local AI planner so the first command is fast."""
        if self.planner is None:
            from planner import Planner
            planner = Planner()
            description = planner.warm()
            self.planner = planner
            return description
        return 'ready'

    def decide(self, request):
        started = time.perf_counter()
        if request.get('engine') == 'ai' and request.get('final'):
            return self.plan(request, started)
        decision = candidate(request['text'], request.get('final', False), request.get('completed', []))
        result = {**decision, 'id': request['id'], 'text': request['text'], 'final': request.get('final', False), 'engine': request.get('engine', 'exact')}
        result['ms'] = round((time.perf_counter() - started) * 1000)
        return result

    def plan(self, request, started):
        text = request['text']
        cancelled = candidate(text, True)
        if cancelled['action'] == 'cancel':
            result = cancelled
        else:
            self.load()
            result = {'action': 'plan', **self.planner.plan(text[:2000])}
        result.update(id=request['id'], text=text, final=True, engine='ai',
                      ms=round((time.perf_counter() - started) * 1000))
        return result


def main():
    engine = Engine()
    for line in sys.stdin:
        try:
            request = json.loads(line)
            if request.get('type') == 'load':
                result = {'type': 'ready', 'device': engine.load()}
            else:
                result = engine.decide(request)
        except Exception as error:
            result = {'type': 'error', 'message': str(error), 'id': request.get('id') if 'request' in locals() else None}
        print(json.dumps(result), flush=True)

if __name__ == '__main__':
    main()
