#!/usr/bin/env python3
"""Deterministically repackage reviewed docopt 0.6.2; never execute its setup/code."""
import argparse
import base64
import csv
import email.parser
import hashlib
import io
import json
from pathlib import Path
import stat
import tarfile
import zipfile

ARCHIVE = (25901, '49b3a825280bd66b3aa83585ef59c4a8c82f2c8a522dbe754a8bc8d08c85c491')
FILES = {
    'docopt.py': (19946, '44c650ebd833d852c8731fa3f0c5759506309622300e4c1954a540d78572cc54'),
    'PKG-INFO': (21525, 'fd7d31e84e7f48c0ee013ba13a7369db9c652a0acbb941d24e159cf7894cf6c8'),
    'LICENSE-MIT': (1097, '3d5df78f592ff2433c3c6ce4984091b7f497059ddb8c6b08a061ba48e37b67f2'),
    'setup.py': (842, '0196d5c4667cbe5bf46343b944c59c81fbefe595dd1ad8644aa7fbc7466a2efc'),
    'setup.cfg': (82, '39786a7a9f03f6a0b9af31e79b0af40498f1507f307efb7cada6dcae978d3c55'),
}
FILENAME = 'docopt-0.6.2-py2.py3-none-any.whl'
DIST = 'docopt-0.6.2.dist-info/'


def sha(data): return hashlib.sha256(data).hexdigest()


def read_source(path, archive_pin, file_pins):
    if not stat.S_ISREG(path.lstat().st_mode) or path.stat().st_size != archive_pin[0]:
        raise ValueError('regular pinned source archive required')
    raw = path.read_bytes()
    if sha(raw) != archive_pin[1]: raise ValueError('source archive hash mismatch')
    result, seen = {}, set()
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as archive:
        for count, member in enumerate(archive, 1):
            if count > 1000 or member.name in seen: raise ValueError('duplicate or oversized source member list')
            seen.add(member.name)
            prefix = 'docopt-0.6.2/'
            if not member.name.startswith(prefix): continue
            name = member.name[len(prefix):]
            if name not in file_pins: continue
            expected_size, expected_hash = file_pins[name]
            if not member.isfile() or member.size != expected_size or member.size > 100_000:
                raise ValueError('source member type/size mismatch')
            data = archive.extractfile(member).read(100_001)
            if len(data) != expected_size or sha(data) != expected_hash: raise ValueError('source member hash mismatch')
            result[name] = data
    if set(result) != set(file_pins): raise ValueError('source member missing')
    return result


def wheel_bytes(files, provenance):
    metadata = email.parser.BytesParser().parsebytes(files['PKG-INFO'])
    if metadata['Name'] != 'docopt' or metadata['Version'] != '0.6.2': raise ValueError('source identity mismatch')
    if any(metadata.get_all(field, []) for field in ('Requires', 'Requires-Dist', 'Provides-Extra')):
        raise ValueError('unexpected source dependency declaration')
    # setup.py's exact reviewed hash declares one py_module and no requirements
    # or entry points. Keep source and original metadata bytes unchanged.
    entries = {
        'docopt.py': files['docopt.py'], DIST+'METADATA': files['PKG-INFO'],
        DIST+'licenses/LICENSE-MIT': files['LICENSE-MIT'],
        DIST+'WHEEL': b'Wheel-Version: 1.0\nGenerator: Dot-reviewed-docopt-repack-1\nRoot-Is-Purelib: true\nTag: py2-none-any\nTag: py3-none-any\n',
        DIST+'SOURCE.json': (json.dumps(provenance,sort_keys=True,indent=2)+'\n').encode(),
    }
    record = io.StringIO(newline=''); writer = csv.writer(record,lineterminator='\n')
    for name, data in sorted(entries.items()):
        checksum = base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b'=').decode()
        writer.writerow([name, 'sha256='+checksum, len(data)])
    writer.writerow([DIST+'RECORD', '', '']); entries[DIST+'RECORD'] = record.getvalue().encode()
    output = io.BytesIO()
    with zipfile.ZipFile(output, 'w', compression=zipfile.ZIP_STORED) as archive:
        for name, data in sorted(entries.items()):
            info = zipfile.ZipInfo(name,date_time=(1980,1,1,0,0,0)); info.create_system = 3
            info.external_attr = (stat.S_IFREG | 0o644) << 16
            archive.writestr(info,data)
    return output.getvalue()


def build(archive, destination):
    archive, destination = Path(archive), Path(destination)
    if destination.name != FILENAME or destination.exists() or destination.is_symlink():
        raise ValueError('fresh exact wheel destination required')
    files = read_source(archive, ARCHIVE, FILES)
    provenance = {'kind':'reviewed_source_repack_not_publisher_wheel','source':'PyPI docopt 0.6.2',
        'archive_bytes':ARCHIVE[0], 'archive_sha256':ARCHIVE[1], 'source_files':
        {name:{'bytes':size,'sha256':checksum} for name,(size,checksum) in FILES.items()},
        'runtime_source_modified':False,'setup_executed':False,'package_imported':False,
        'packaging_changes':'Deterministic wheel container, WHEEL, RECORD and provenance only; original module, metadata and MIT license retained.'}
    data = wheel_bytes(files,provenance)
    with destination.open('xb') as stream: stream.write(data)
    return {'filename':FILENAME,'bytes':len(data),'sha256':sha(data),'metadata_sha256':sha(files['PKG-INFO']),
            'provenance':provenance,'neural_or_package_execution':False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('archive'); parser.add_argument('destination')
    args = parser.parse_args(); print(json.dumps(build(args.archive,args.destination),indent=2))
