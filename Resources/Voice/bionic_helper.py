#!/usr/bin/env python3
"""Dot's versioned offline warm helper, derived from Bionic Voice (MIT).
Baseline: Emin-dev/Bionic 5166bf4915d436c505f4731667daf5b9375b5e77.
See BIONIC-LICENSE.txt. This is NOT the unknown installed Bionic daemon.
"""
import argparse
import contextlib
import importlib.util
import importlib.metadata
import json
import os
from pathlib import Path
import queue
import sys
import threading
import uuid
import wave

PROTOCOL = 1
MAX_TEXT = 1000
MAX_LINE = 8192
MAX_SAMPLES = 24000 * 60
VOICE = 'bf_isabella'
PROTOCOL_OUT = sys.stdout
OUTPUT_LOCK = threading.Lock()


def emit(message):
    # redirect_stdout is process-global; protocol output must never follow it.
    with OUTPUT_LOCK:
        print(json.dumps({'protocol': PROTOCOL, **message}, separators=(',', ':')), file=PROTOCOL_OUT, flush=True)


def parse_request(line):
    if len(line) > MAX_LINE:
        raise ValueError('request_too_large')
    item = json.loads(line)
    if not isinstance(item, dict):
        raise ValueError('invalid_request')
    if type(item.get('protocol')) is not int or item['protocol'] != PROTOCOL:
        raise ValueError('unsupported_protocol')
    kind = item.get('type')
    if kind in ('cancel', 'shutdown'):
        return item
    if kind != 'speak':
        raise ValueError('unsupported_request')
    for key in ('id', 'turn'):
        if str(uuid.UUID(item[key])).lower() != item[key].lower():
            raise ValueError('invalid_request_id')
    if not isinstance(item.get('text'), str) or not 0 < len(item['text'].strip()) <= MAX_TEXT:
        raise ValueError('invalid_text')
    return item


class WarmVoice:
    def __init__(self, root):
        # The Swift host additionally runs this process inside a no-network OS sandbox.
        os.environ['HF_HUB_OFFLINE'] = '1'
        os.environ['TRANSFORMERS_OFFLINE'] = '1'
        os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
        self.root = Path(root).resolve(strict=True)
        model = self.root / 'model'
        voice_path = model / 'voices' / (VOICE + '.pt')
        for path in (model / 'config.json', model / 'kokoro-v1_0.pth', voice_path):
            if not path.is_file():
                raise RuntimeError('local_voice_assets_missing')
        for package in ('kokoro', 'misaki'):
            if importlib.metadata.version(package) != '0.9.4':
                raise RuntimeError('unsupported_voice_package_version')
        if (importlib.util.find_spec('en_core_web_sm') is None or
                importlib.metadata.version('en-core-web-sm') != '3.8.0'):
            raise RuntimeError('english_g2p_model_missing')
        import spacy.cli
        def no_download(*args, **kwargs):
            raise RuntimeError('downloads_disabled')
        spacy.cli.download = no_download
        from misaki.espeak import EspeakFallback
        # Fail early if local eSpeak cannot initialize. Kokoro constructs its
        # own fallback later and otherwise silently tolerates its failure.
        EspeakFallback(british=True)
        import numpy as np
        import torch
        from kokoro.model import KModel
        from kokoro import KPipeline
        self.np, self.torch = np, torch
        # Kokoro 0.9.4 treats string voices as comma-separated names, even when
        # they are local paths. The audited bundle may itself contain a comma.
        # Load only the verified local asset and bypass that name/download path.
        self.voice = torch.load(str(voice_path), map_location='cpu', weights_only=True)
        # This exact Kokoro release dispatches tensor voices as CPU FloatTensor,
        # not as arbitrary Tensor dtypes; reject rather than enter its name path.
        if not isinstance(self.voice, torch.FloatTensor):
            raise RuntimeError('invalid_local_voice_asset')
        self.model = KModel(repo_id='hexgrad/Kokoro-82M', config=str(model / 'config.json'),
                            model=str(model / 'kokoro-v1_0.pth')).to('cpu').eval()
        self.pipeline = KPipeline(lang_code='b', model=self.model, repo_id='hexgrad/Kokoro-82M')
        if self.pipeline.g2p.fallback is None:
            raise RuntimeError('local_espeak_fallback_missing')

    def render(self, text, cancelled):
        chunks = []
        samples = 0
        with self.torch.inference_mode():
            for item in self.pipeline(text, voice=self.voice, speed=1.0):
                if cancelled():
                    return None
                tensors = [value for value in item if self.torch.is_tensor(value)]
                if tensors:
                    audio = tensors[0].reshape(-1).cpu()
                    samples += audio.numel()
                    if samples > MAX_SAMPLES:
                        raise RuntimeError('audio_too_long')
                    chunks.append(audio)
        if cancelled():
            return None
        if not chunks:
            raise RuntimeError('empty_audio')
        audio = self.torch.cat(chunks).numpy()
        if not self.np.isfinite(audio).all():
            raise RuntimeError('nonfinite_audio')
        return self.np.clip(audio, -1, 1)

    def write_wav(self, path, audio):
        # Baseline PCM encoding: mono 24 kHz signed 16 bit little-endian.
        pcm = (audio * 32767).astype('<i2')
        with wave.open(str(path), 'wb') as handle:
            handle.setnchannels(1); handle.setsampwidth(2); handle.setframerate(24000)
            handle.writeframes(pcm.tobytes())


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    output = Path(args.output).resolve(strict=True)
    if not output.is_dir() or output.stat().st_uid != os.getuid() or output.stat().st_mode & 0o077:
        raise RuntimeError('output_directory_not_private')
    try:
        with contextlib.redirect_stdout(sys.stderr):
            voice = WarmVoice(args.root)
    except Exception:
        emit({'event': 'unavailable', 'code': 'local_voice_setup_failed'})
        return 2
    jobs = queue.Queue(maxsize=24)
    epoch = [0]
    lock = threading.Lock()
    closed = threading.Event()
    def current_epoch():
        with lock: return epoch[0]
    def worker():
        while not closed.is_set():
            try: item, generation = jobs.get(timeout=0.2)
            except queue.Empty: continue
            path = None
            try:
                cancelled = lambda: generation != current_epoch() or closed.is_set()
                if cancelled(): continue
                with contextlib.redirect_stdout(sys.stderr):
                    audio = voice.render(item['text'], cancelled)
                if audio is None or cancelled(): continue
                path = output / ('audio-' + str(uuid.uuid4()) + '.wav')
                voice.write_wav(path, audio)
                if cancelled(): path.unlink(missing_ok=True); continue
                emit({'event': 'audio', 'id': item['id'], 'turn': item['turn'], 'file': path.name, 'samples': len(audio), 'sample_rate': 24000})
            except Exception:
                if path: path.unlink(missing_ok=True)
                emit({'event': 'error', 'id': item['id'], 'turn': item['turn'], 'code': 'synthesis_failed'})
            finally: jobs.task_done()
    threading.Thread(target=worker, daemon=True).start()
    emit({'event': 'hello', 'engine': 'kokoro', 'voice': VOICE, 'sample_rate': 24000, 'offline': True})
    while True:
        line = sys.stdin.buffer.readline(MAX_LINE + 1)
        if not line: break
        try:
            item = parse_request(line)
            if item['type'] == 'shutdown': break
            if item['type'] == 'cancel':
                with lock: epoch[0] += 1
                while True:
                    try: jobs.get_nowait(); jobs.task_done()
                    except queue.Empty: break
                emit({'event': 'cancelled'})
            else:
                try: jobs.put_nowait((item, current_epoch()))
                except queue.Full:
                    emit({'event': 'error', 'id': item['id'], 'turn': item['turn'], 'code': 'queue_full'})
        except Exception:
            emit({'event': 'unavailable', 'code': 'invalid_protocol_request'})
            break
    closed.set()
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
