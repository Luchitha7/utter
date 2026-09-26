import plistlib
import sys
import tempfile
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
from planner import Apps, Planner


def call(tool, **arguments):
    return {"function": {"name": tool, "arguments": arguments}}


class PlannerTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        for name in ['Notes', 'Safari', 'Google Chrome', 'Spotify', 'System Settings', 'zoom.us', 'Visual Studio Code']:
            contents = Path(self.root.name) / f'{name}.app' / 'Contents'
            contents.mkdir(parents=True)
            (contents / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'test.' + name.lower()}))
        (Path(self.root.name) / 'Broken.app').mkdir()
        self.apps = Apps(dirs=[Path(self.root.name)], extra=[])

    def tearDown(self):
        self.root.cleanup()

    def planner(self, *calls, content=''):
        return Planner(apps=self.apps, shortcuts=['Water Eject', 'Music Quiz'],
                       chat=lambda messages: {'content': content, 'tool_calls': list(calls)})

    def test_app_resolution(self):
        for spoken, expected in [('spotify', 'Spotify'), ('the Chrome app', 'Google Chrome'), ('settings', 'System Settings'),
                                 ('zoom', 'zoom.us'), ('VS Code', 'Visual Studio Code'), ('Safari.', 'Safari')]:
            self.assertEqual(self.apps.resolve(spoken).stem, expected, spoken)
        self.assertIsNone(self.apps.resolve('photoshop'))
        self.assertIsNone(self.apps.resolve('broken'))

    def test_multi_step_plan(self):
        result = self.planner(call('open_app', name='Notes'), call('create_note', body='buy milk')).plan('open notes and note buy milk')
        self.assertEqual([s['tool'] for s in result['steps']], ['open_app', 'create_note'])
        self.assertEqual(result['steps'][0]['key'], 'open:test.notes')

    def test_note_keeps_exact_words(self):
        result = self.planner(call('create_note', body='Buy milk.')).plan('create a note saying buy milk and do not cancel')
        self.assertEqual(result['steps'][0]['body'], 'buy milk and do not cancel')

    def test_rejects_unknowns(self):
        result = self.planner(call('open_app', name='Photoshop'), call('run_shortcut', name='Delete Everything'),
                              call('shell', command='rm -rf ~'), call('open_url', url='javascript:alert(1)')).plan('x')
        self.assertEqual(result['steps'], [])
        self.assertIn('Photoshop', result['say'])
        self.assertIn('Delete Everything', result['say'])

    def test_shortcut_volume_url_search(self):
        result = self.planner(call('run_shortcut', name='water eject'), call('set_volume', percent=150),
                              call('open_url', url='youtube.com'), call('web_search', query='weather in colombo')).plan('x')
        steps = result['steps']
        self.assertEqual(steps[0]['name'], 'Water Eject')
        self.assertEqual(steps[1]['percent'], 100)
        self.assertEqual(steps[2]['url'], 'https://youtube.com')
        self.assertEqual(steps[3]['url'], 'https://www.google.com/search?q=weather+in+colombo')

    def test_reminder_due_validation(self):
        good = self.planner(call('create_reminder', title='call mum', due='2026-09-26T17:00')).plan('x')['steps'][0]
        bad = self.planner(call('create_reminder', title='call mum', due='five pm')).plan('x')['steps'][0]
        self.assertEqual(good['due'], '2026-09-26T17:00')
        self.assertIsNone(bad['due'])

    def test_no_tools_replies(self):
        result = self.planner(content='<think></think>I can only control your Mac.').plan('what is the capital of France')
        self.assertEqual(result, {'steps': [], 'say': 'I can only control your Mac.'})
        robotic = self.planner(content='None of the tools are called.')
        self.assertEqual(robotic.plan("don't open spotify")['say'], 'OK, I won’t do anything.')
        self.assertIn('reminders', robotic.plan('what is the capital of france')['say'])

    def test_explicit_open_notes_is_kept(self):
        result = self.planner(call('create_note', body='x')).plan('open notes and create a note saying buy milk')
        self.assertEqual([s['tool'] for s in result['steps']], ['open_app', 'create_note'])

    def test_duplicate_steps_collapse(self):
        result = self.planner(call('open_app', name='Safari'), call('open_app', name='safari')).plan('x')
        self.assertEqual(len(result['steps']), 1)


if __name__ == '__main__':
    unittest.main()
