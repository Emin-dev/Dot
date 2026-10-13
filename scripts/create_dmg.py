#!/usr/bin/env python3
"""Create a fresh UDZO image with the supported OS tool; preserve previous output."""
import argparse
import os
from pathlib import Path
import platform
import stat
import subprocess
import tempfile


def select_backend(version, help_text):
    major = int(version.split('.')[0])
    if '--volumeName' in help_text and '--format' in help_text:
        return 'diskutil'
    if major >= 27:
        raise RuntimeError('Supported diskutil image create from capability is unavailable')
    return 'hdiutil'


def native_backend():
    if platform.system() != 'Darwin':
        raise RuntimeError('Disk image creation requires macOS')
    help_text = ''
    if Path('/usr/sbin/diskutil').is_file():
        # Missing positional arguments request usage only; no image is created.
        help_text = subprocess.run(['/usr/sbin/diskutil', 'image', 'create', 'from'],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT, timeout=10, check=False).stdout.decode(errors='replace')
    return select_backend(platform.mac_ver()[0], help_text)


def output_identity(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return None
    if not stat.S_ISREG(info.st_mode):
        raise ValueError('Existing output must be a regular non-symlink file')
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns


def create_image(source, destination, backend=None):
    source = Path(source).resolve(strict=True)
    destination = Path(destination)
    destination = destination.parent.resolve(strict=True) / destination.name
    if not source.is_dir() or destination.suffix.lower() != '.dmg':
        raise ValueError('Expected source directory and .dmg output')
    if destination.is_relative_to(source):
        raise ValueError('Output must not be inside the image source')
    previous = output_identity(destination)
    backend = backend or native_backend()
    if backend not in ('diskutil', 'hdiutil'):
        raise ValueError('Unsupported image backend')
    with tempfile.TemporaryDirectory(prefix='.dot-dmg-', dir=destination.parent) as folder:
        image = Path(folder) / 'Dot.dmg'
        if backend == 'diskutil':
            command = ['/usr/sbin/diskutil', 'image', 'create', 'from', '--volumeName', 'Dot', '--format', 'UDZO', str(source), str(image)]
        else:
            command = ['/usr/bin/hdiutil', 'create', '-volname', 'Dot', '-srcfolder', str(source), '-format', 'UDZO', '-o', str(image)]
        # Never suppress diagnostics or retry a failed modern operation with the old tool.
        subprocess.run(command, stdin=subprocess.DEVNULL, check=True, timeout=600)
        result = output_identity(image)
        if result is None or result[2] == 0:
            raise RuntimeError('Image tool produced no regular nonempty image')
        if output_identity(destination) != previous:
            raise RuntimeError('Output changed during packaging; refusing replacement')
        backup = None
        if previous is not None:
            backup = Path(tempfile.mkdtemp(prefix=destination.stem + '-previous-', dir=destination.parent)) / destination.name
            os.link(destination, backup, follow_symlinks=False)
        os.replace(image, destination)  # Same filesystem, atomic publication of complete bytes.
        if backup is not None:
            print('Preserved previous disk image:', backup)
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source'); parser.add_argument('destination')
    arguments = parser.parse_args()
    print('Created disk image:', create_image(arguments.source, arguments.destination))
