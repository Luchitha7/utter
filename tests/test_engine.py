import sys
import unittest
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'backend'))
from engine import candidate

class CommandTests(unittest.TestCase):
    def test_partial_then_note(self):
        self.assertEqual(candidate('open')['action'], 'wait')
        self.assertEqual(candidate('open notes and create')['action'], 'open')
        completed = ['open:com.apple.Notes']
        phrase = 'Open Notes and create a note saying buy milk tomorrow'
        self.assertEqual(candidate(phrase, False, completed)['action'], 'wait')
        self.assertEqual(candidate(phrase, True, completed)['body'], 'buy milk tomorrow')
        self.assertEqual(candidate(phrase, True, completed + ['note'])['action'], 'wait')

    def test_negation_and_conversation(self):
        for text in ["don't open notes", 'how do I open notes', 'open notepad', 'open notes actually safari', 'open notes cancel', 'open safari instead', 'open notes do not']:
            self.assertIn(candidate(text)['action'], ('wait', 'cancel'), text)

    def test_literal_note_content(self):
        result = candidate('create a note saying do not cancel the meeting', True, ['open:com.apple.Notes'])
        self.assertEqual(result['body'], 'do not cancel the meeting')

    def test_exact_application(self):
        self.assertEqual(candidate('please open the google chrome app')['bundle'], 'com.google.Chrome')
        self.assertEqual(candidate('open noteskeeper')['action'], 'wait')
        self.assertEqual(candidate('open notes', completed=['open:com.apple.Notes'])['action'], 'wait')

if __name__ == '__main__':
    unittest.main()
