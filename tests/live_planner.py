"""Live check against the local Ollama model. Plans only; nothing is executed.

Usage: python3 tests/live_planner.py
"""
import sys
import time
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
from planner import Planner

CASES = [
    ('open spotify', ['open_app']),
    ('could you pull up chrome for me', ['open_app']),
    ('open notes and create a note saying buy milk and bread tomorrow', ['open_app', 'create_note']),
    ('remind me to call mum at 5', ['create_reminder']),
    ('remind me tomorrow morning at 9 to submit the report', ['create_reminder']),
    ('search the web for pasta recipes', ['open_url']),
    ('go to youtube.com', ['open_url']),
    ('set the volume to 30 percent', ['set_volume']),
    ('mute', ['set_volume']),
    ('run my water eject shortcut', ['run_shortcut']),
    ('open safari actually no open chrome', ['open_app']),
    ("don't open spotify", []),
    ('what is the capital of france', []),
    ('open whatsapp and then spotify', ['open_app', 'open_app']),
]


def main():
    planner = Planner()
    started = time.perf_counter()
    print('warm-up:', planner.warm(), f'{time.perf_counter() - started:.1f}s')
    passed = 0
    for text, expected in CASES:
        started = time.perf_counter()
        result = planner.plan(text)
        ms = (time.perf_counter() - started) * 1000
        tools = [s['tool'] for s in result['steps']]
        ok = tools == expected
        passed += ok
        detail = '; '.join(s['summary'] for s in result['steps']) or result['say']
        print(f"{'PASS' if ok else 'FAIL'} {ms:5.0f} ms  {text!r:62} -> {detail}")
    print(f'{passed}/{len(CASES)} passed')


if __name__ == '__main__':
    main()
