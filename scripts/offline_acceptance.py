#!/usr/bin/env python3
"""Bind native acceptance evidence to an exact relocatable app. Never runs neural code."""
import argparse
import hashlib
import json
from pathlib import Path
import stat

CHECKS = ('relocated_launch', 'empty_external_caches', 'outbound_network_denied',
          'english_microphone_transcription', 'splash_exact_model_reply', 'audible_kokoro_reply',
          'screen_opt_out_persists', 'screen_permission_denial_honest',
          'interrupt_cancels_audio_and_generation', 'quit_reaps_owned_children', 'single_companion_surface')


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''): result.update(block)
    return result.hexdigest()


def fingerprint(app):
    app = Path(app).resolve(strict=True)
    result = hashlib.sha256()
    paths = sorted(app.rglob('*'))
    if not paths or len(paths) > 100_000: raise ValueError('invalid app closure')
    total = 0
    for path in paths:
        info = path.lstat(); relative = path.relative_to(app).as_posix()
        if stat.S_ISLNK(info.st_mode):
            if not path.resolve(strict=True).is_relative_to(app): raise ValueError('external app symlink')
            value = ['link', relative, str(path.readlink())]
        elif stat.S_ISREG(info.st_mode):
            total += info.st_size
            if total > 60_000_000_000: raise ValueError('oversized app')
            value = ['file', relative, info.st_mode & 0o777, info.st_size, digest(path)]
        elif stat.S_ISDIR(info.st_mode): value = ['directory', relative]
        else: raise ValueError('unsupported app entry')
        result.update(json.dumps(value, separators=(',', ':'), ensure_ascii=True).encode() + b'\n')
    return result.hexdigest()


def verify(app, receipt):
    app = Path(app).resolve(strict=True); receipt = Path(receipt)
    if not stat.S_ISREG(receipt.lstat().st_mode) or receipt.stat().st_size > 1_000_000:
        raise ValueError('bounded regular acceptance record required')
    record = json.loads(receipt.read_text())
    provenance = json.loads((app / 'Contents/Resources/build-provenance.json').read_text())
    download_on_first_launch = provenance.get('llm_weights_download_on_first_launch')
    models_bundled = provenance.get('models_bundled')
    if provenance.get('runtime_bundled') is not True:
        raise ValueError('runtime provenance required')
    complete_offline = models_bundled is True and download_on_first_launch is False
    first_launch_download = models_bundled is False \
        and provenance.get('models_downloaded') is not True and download_on_first_launch is True
    if not (complete_offline or first_launch_download):
        raise ValueError('complete offline or first-launch-download provenance required')
    if record.get('schema_version') != 1 or record.get('commit') != provenance.get('commit'):
        raise ValueError('acceptance source mismatch')
    if record.get('app_fingerprint_sha256') != fingerprint(app): raise ValueError('acceptance app mismatch')
    checks = record.get('checks', {})
    if set(checks) != set(CHECKS): raise ValueError('all native checks required')
    for name in CHECKS:
        check = checks[name]
        if check.get('passed') is not True: raise ValueError('native check failed: ' + name)
        relative = check.get('evidence_path', '')
        if not relative or Path(relative).is_absolute() or '..' in Path(relative).parts:
            raise ValueError('invalid evidence path')
        path = receipt.parent / relative
        if not path.resolve(strict=True).is_relative_to(receipt.parent.resolve(strict=True)) or not stat.S_ISREG(path.lstat().st_mode):
            raise ValueError('external/nonregular evidence')
        if not 1 <= path.stat().st_size <= 20_000_000 or digest(path) != check.get('evidence_sha256'):
            raise ValueError('evidence hash/size mismatch')
    return {'verified': True, 'commit': record['commit'], 'app_fingerprint_sha256': record['app_fingerprint_sha256']}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app'); parser.add_argument('--receipt'); args = parser.parse_args()
    print(json.dumps(verify(args.app, args.receipt) if args.receipt else {'app_fingerprint_sha256': fingerprint(args.app)}))
