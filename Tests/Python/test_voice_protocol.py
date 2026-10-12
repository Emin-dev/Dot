import importlib.util
import json
from pathlib import Path
import unittest
import uuid

path = Path(__file__).resolve().parents[2] / 'Resources/Voice/bionic_helper.py'
spec = importlib.util.spec_from_file_location('voice_helper', path)
helper = importlib.util.module_from_spec(spec); spec.loader.exec_module(helper)

class VoiceProtocolTests(unittest.TestCase):
    def valid(self): return {'protocol': 1, 'type': 'speak', 'id': str(uuid.uuid4()), 'turn': str(uuid.uuid4()), 'text': 'Hello.'}
    def test_valid_request(self):
        item=self.valid(); self.assertEqual(helper.parse_request(json.dumps(item)), item)
    def test_unknown_protocol_rejected(self):
        item=self.valid(); item['protocol']=2
        with self.assertRaises(ValueError): helper.parse_request(json.dumps(item))
    def test_text_bound(self):
        item=self.valid(); item['text']='a'*1001
        with self.assertRaises(ValueError): helper.parse_request(json.dumps(item))
    def test_invalid_id_rejected(self):
        item=self.valid(); item['id']='../../outside'
        with self.assertRaises(ValueError): helper.parse_request(json.dumps(item))
    def test_line_bound(self):
        with self.assertRaises(ValueError): helper.parse_request(' '*8193)
    def test_cancel_and_shutdown(self):
        for value in ('cancel','shutdown'):
            self.assertEqual(helper.parse_request(json.dumps({'protocol':1,'type':value}))['type'],value)


class HelperRuntimeTests(unittest.TestCase):
    def test_protocol_output_survives_library_stdout_redirect(self):
        import contextlib, io
        from unittest.mock import patch
        protocol, diagnostics = io.StringIO(), io.StringIO()
        with patch.object(helper, 'PROTOCOL_OUT', protocol), contextlib.redirect_stdout(diagnostics):
            helper.emit({'event': 'cancelled'})
        self.assertEqual(json.loads(protocol.getvalue())['event'], 'cancelled')
        self.assertEqual(diagnostics.getvalue(), '')

    def test_boolean_protocol_and_non_object_rejected(self):
        for value in ({'protocol': True, 'type': 'cancel'}, []):
            with self.assertRaises(ValueError): helper.parse_request(json.dumps(value))

    def run_helper(self, interrupt=False):
        import queue, tempfile, threading, wave
        from unittest.mock import patch
        requests, events = queue.Queue(), queue.Queue()
        entered, resume = threading.Event(), threading.Event()
        instances = []
        class FakeVoice:
            def __init__(self, root): instances.append(self)
            def render(self, text, cancelled):
                if text == 'hold':
                    entered.set(); resume.wait(timeout=3)
                return None if cancelled() else [0] * 240
            def write_wav(self, path, audio):
                with wave.open(str(path), 'wb') as output:
                    output.setnchannels(1); output.setsampwidth(2); output.setframerate(24000)
                    output.writeframes(b'\0\0' * len(audio))
        class Input:
            @property
            def buffer(self): return self
            def readline(self, limit): return requests.get(timeout=5)
        def send(kind, **fields):
            requests.put((json.dumps({'protocol': 1, 'type': kind, **fields}) + '\n').encode())
        def speak(text, turn):
            request = str(uuid.uuid4()); send('speak', id=request, turn=turn, text=text); return request
        def next_event(): return events.get(timeout=4)
        with tempfile.TemporaryDirectory() as directory, \
             patch.object(helper, 'WarmVoice', FakeVoice), patch.object(helper, 'emit', events.put), \
             patch.object(helper.sys, 'stdin', Input()), \
             patch.object(helper.sys, 'argv', ['helper', '--root', directory, '--output', directory]):
            thread = threading.Thread(target=helper.main)
            thread.start()
            try:
                self.assertEqual(next_event()['event'], 'hello')
                turn = str(uuid.uuid4())
                if interrupt:
                    old = speak('hold', turn); self.assertTrue(entered.wait(timeout=2))
                    send('cancel'); self.assertEqual(next_event()['event'], 'cancelled')
                    resume.set()
                    current = speak('new', str(uuid.uuid4()))
                    event = next_event(); self.assertEqual(event['id'], current)
                    self.assertNotEqual(event['id'], old)
                else:
                    first, second = speak('one', turn), speak('two', turn)
                    a, b = next_event(), next_event()
                    self.assertEqual([a['id'], b['id']], [first, second])
                    self.assertNotEqual(a['file'], b['file'])
                self.assertEqual(len(instances), 1)
            finally:
                resume.set(); send('shutdown'); thread.join(timeout=3)
                self.assertFalse(thread.is_alive())
    def test_warm_instance_reused_and_ordered_unique_output(self): self.run_helper()
    def test_cancel_suppresses_inflight_audio_and_serves_new_turn(self): self.run_helper(interrupt=True)

if __name__ == '__main__': unittest.main()
