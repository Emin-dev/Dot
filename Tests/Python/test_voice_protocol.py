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
    def initialize_with_fake_packages(self, root, voice_is_tensor=True,
                                      fallback_available=True, english_version='3.8.0',
                                      voice_is_float32=True):
        import contextlib, types
        from unittest.mock import Mock, patch
        model = Path(root) / 'model'; (model / 'voices').mkdir(parents=True)
        for name in ('config.json', 'kokoro-v1_0.pth', 'voices/bf_isabella.pt'):
            (model / name).write_bytes(b'inert test fixture, never deserialized')
        class FakeTensor: pass
        class FakeFloatTensor(FakeTensor): pass
        tensor = (FakeFloatTensor() if voice_is_float32 else FakeTensor()) if voice_is_tensor else object()
        torch = types.SimpleNamespace(load=Mock(return_value=tensor),
            FloatTensor=FakeFloatTensor, is_tensor=lambda value: isinstance(value, FakeTensor),
            inference_mode=contextlib.nullcontext)
        pipeline = Mock(return_value=[])
        pipeline.g2p = types.SimpleNamespace(fallback=object() if fallback_available else None)
        spacy = types.ModuleType('spacy'); spacy.cli = types.ModuleType('spacy.cli')
        modules = {'torch': torch, 'numpy': types.ModuleType('numpy'),
            'spacy': spacy, 'spacy.cli': spacy.cli,
            'misaki': types.ModuleType('misaki'),
            'misaki.espeak': types.SimpleNamespace(EspeakFallback=Mock()),
            'kokoro': types.SimpleNamespace(KPipeline=Mock(return_value=pipeline)),
            'kokoro.model': types.SimpleNamespace(KModel=Mock())}
        with patch.dict(helper.sys.modules, modules), \
             patch.object(helper.importlib.metadata, 'version', side_effect=lambda name: english_version if name == 'en-core-web-sm' else '0.9.4'), \
             patch.object(helper.importlib.util, 'find_spec', return_value=object()), \
             patch.dict(helper.os.environ):
            voice = helper.WarmVoice(root)
        return voice, torch, tensor, pipeline, model / 'voices/bf_isabella.pt'

    def test_comma_and_unicode_bundle_path_passes_local_tensor_not_voice_names(self):
        import tempfile
        with tempfile.TemporaryDirectory(prefix='Dot, local voix é ') as root:
            voice, torch, tensor, pipeline, path = self.initialize_with_fake_packages(root)
            torch.load.assert_called_once_with(str(path.resolve(strict=True)), map_location='cpu', weights_only=True)
            self.assertIs(voice.voice, tensor)
            # The empty fake generator avoids neural execution while exercising
            # the real helper call into Kokoro's voice dispatch boundary.
            with self.assertRaisesRegex(RuntimeError, 'empty_audio'):
                voice.render('Hello.', lambda: False)
            pipeline.assert_called_once_with('Hello.', voice=tensor, speed=1.0)

    def test_bundle_parent_alias_loads_the_canonical_local_asset(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            real = Path(directory) / 'real, local bundle'; real.mkdir()
            alias = Path(directory) / 'alias'; alias.symlink_to(real, target_is_directory=True)
            _, torch, _, _, path = self.initialize_with_fake_packages(alias)
            self.assertNotEqual(str(path), str(path.resolve(strict=True)))
            torch.load.assert_called_once_with(str(path.resolve(strict=True)), map_location='cpu', weights_only=True)

    def test_non_tensor_local_voice_is_rejected_before_pipeline_use(self):
        import tempfile
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaisesRegex(RuntimeError, 'invalid_local_voice_asset'):
                self.initialize_with_fake_packages(root, voice_is_tensor=False)

    def test_actual_pipeline_missing_espeak_fallback_is_rejected(self):
        import tempfile
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaisesRegex(RuntimeError, 'local_espeak_fallback_missing'):
                self.initialize_with_fake_packages(root, fallback_available=False)

    def test_non_float32_tensor_cannot_fall_through_to_voice_name_dispatch(self):
        import tempfile
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaisesRegex(RuntimeError, 'invalid_local_voice_asset'):
                self.initialize_with_fake_packages(root, voice_is_float32=False)

    def test_importable_english_model_with_wrong_distribution_version_is_rejected(self):
        import tempfile
        with tempfile.TemporaryDirectory() as root:
            with self.assertRaisesRegex(RuntimeError, 'english_g2p_model_missing'):
                self.initialize_with_fake_packages(root, english_version='3.7.0')

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
