#!/usr/bin/env python3
"""Acquire/reconstruct one exact historical BUILD-ONLY payload; never execute it."""
from pathlib import Path
import argparse
import json
import platform
import sys

from fetch_search_inputs import fetch
from search_download import safe_target, validate_url
from search_payload import assemble, clean_name, hash_file
from search_proxy_canary_support import verify_payload, verify_source_lock

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / 'packaging/search/search-lock-native-owner.json'
HELPERS = ROOT / 'Tests/Fixtures/search-proxy-native-owner/helpers'
LOCK_SHA256 = '0f094efe0cd2dc4d459a87ec9618884bd4f05bacd6c834ddd1036e813f2a4b80'
RECEIPT_SHA256 = '4268358594bf02881357334812b8f7ee84764940752071b1febd3ace26adbbab'
INPUT_COUNT, INPUT_BYTES, PAYLOAD_FILES = 33, 59551997, 4824


def runtime_inputs(lock):
    """The assembler's complete closure, excluding unrelated redistribution inputs."""
    items = [('wheels/' + entry['filename'], entry) for entry in lock['wheels']]
    items += [(entry['filename'], entry) for entry in
              (lock['python']['install_only'], lock['searxng']['archive'])]
    if len(items) != INPUT_COUNT or sum(pin['size'] for _, pin in items) != INPUT_BYTES:
        raise ValueError('unexpected historical assembly input count or byte total')
    names = set()
    for name, pin in items:
        clean_name(name)
        validate_url(pin['url'])
        if name in names:
            raise ValueError('duplicate historical input path')
        names.add(name)
    return items


def verify_helpers(lock):
    expected = {item['path'] for item in lock['helper_inputs']}
    if len(expected) != 5 or {p.name for p in HELPERS.iterdir()} != expected:
        raise ValueError('historical helper closure differs')
    for item in lock['helper_inputs']:
        p = safe_target(HELPERS / clean_name(item['path']))
        if not p.is_file() or p.stat().st_size != item['size'] or hash_file(p) != item['sha256']:
            raise ValueError('historical helper identity mismatch: ' + item['path'])


def acquire(lock, inputs, offline):
    items = runtime_inputs(lock)
    for name, pin in items:
        target = safe_target(inputs / name)
        if offline:
            if not target.is_file() or target.stat().st_size != pin['size'] or hash_file(target) != pin['sha256']:
                raise ValueError('offline artifact absent or changed: ' + name)
        else:
            # Existing reviewed transport checks HTTPS origins/redirects, exact
            # size/SHA and cache aliases. No resolver, pip, or build hooks here.
            fetch((name, pin), inputs)
    return items


def prepare(inputs, output, *, offline=False):
    inputs, output = Path(inputs).absolute(), Path(output).absolute()
    if output.exists() or output.is_symlink():
        raise ValueError('canary payload output must be new')
    if output.is_relative_to(ROOT) or '.app' in {part[-4:] for part in output.parts}:
        raise ValueError('canary payload must be independent and outside the source checkout')
    for parent in output.parents:
        if parent.is_symlink():
            raise ValueError('canary output parent must not be an alias')
    lock, lock_identity = verify_source_lock(LOCK, LOCK_SHA256)
    verify_helpers(lock)
    items = acquire(lock, inputs, offline)
    assembled = assemble(lock, inputs, output, HELPERS)
    _, identity = verify_payload(output, RECEIPT_SHA256)
    if identity['payload_file_count'] != PAYLOAD_FILES:
        raise ValueError('historical payload file count differs')
    _, final_lock = verify_source_lock(LOCK, LOCK_SHA256)
    verify_helpers(lock)
    if lock_identity != final_lock:
        raise ValueError('source lock bytes changed during reconstruction')
    return {'schema': 1, 'kind': 'build-only-historical-search-reconstruction',
            'status': 'exact-receipt-and-tree-match', 'native_executed': False,
            'production_acceptance': False, 'production_broker_tested': False,
            'owner_macos_26_4_accepted': False, 'full_neural_app_accepted': False,
            'controller': {'os': sys.platform, 'architecture': platform.machine(),
                           'python': platform.python_version()},
            'input_count': len(items), 'input_bytes': sum(pin['size'] for _, pin in items),
            'acquisition': 'verified-existing-cache' if offline else 'pinned-official-https-or-verified-cache',
            'assembly': assembled, 'payload': identity, **lock_identity,
            'source_sha256': {name: hash_file(ROOT / name) for name in (
                'scripts/prepare_search_proxy_canary_payload.py', 'scripts/search_payload.py',
                'scripts/fetch_search_inputs.py', 'scripts/search_download.py',
                'scripts/search_proxy_canary_support.py')}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--inputs', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--offline', action='store_true', help='require existing exact inputs; never access network')
    args = parser.parse_args()
    print(json.dumps(prepare(args.inputs, args.output, offline=args.offline), sort_keys=True))


if __name__ == '__main__':
    main()
