#!/usr/bin/env python3
"""Actual Darwin capability canary; never native runtime acceptance.

Only fresh temporary synthetic files and a compiled, ad-hoc-signed C fixture are
used. The real finalizer's private primitives run without patches or substituted
observations. An unsupported capability is a nonzero failure, never a skip.
No production approval, manifest, accepted marker, model or owner asset is made.
JSONL on stdout is the bounded diagnostic receipt (including raw output bytes).
The crash exercise tests the real IO primitives in a TEST-ONLY mini-transaction;
it does not fabricate admission to the production finalization writer.
"""
from __future__ import annotations

import base64
import contextlib
import ctypes
import errno
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
FINALIZER = ROOT / 'scripts/reconstruct_runtime_payload.py'
spec = importlib.util.spec_from_file_location('runtime_finalizer_canary_production', FINALIZER)
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

TOTAL_SECONDS = 180
COMMAND_SECONDS = 20
OUTPUT_BYTES = 65536
RECEIPT_BYTES = 4_000_000
DEVELOPER = '/Applications/Xcode_26.3.app/Contents/Developer'
CLANG = DEVELOPER + '/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang'
SDK = DEVELOPER + '/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk'
XCODE = '/Applications/Xcode_26.3.app'
XCODE_VERSION = XCODE + '/Contents/version.plist'
# Observed unchanged before/after Apple-anchor verification in native run
# 38624949109, job 116061609757 (source d4205a0d21ef649a6f58c0dc46105b84814ac7d8).
# Complete 1197984-byte job log SHA-256:
# f4cddf0a66018f741396e0ea6c21e07e2455eabd755e061af69974aa82b998f8
COMPILER_PIN = {'bytes': 272034048,
                'sha256': '15339439a6be4a9d33d281ec040a7e0092190b1c8d7de5f94d824b50ffae0769'}
COMPILER_REQUIREMENT = '=identifier "com.apple.clang" and anchor apple'
HOSTED_IMAGE = {'ImageOS': 'macos15', 'ImageVersion': '20260907.0337.1',
                'RUNNER_OS': 'macOS', 'RUNNER_ARCH': 'ARM64', 'GITHUB_ACTIONS': 'true'}
TOOLCHAIN_POLICY_SECONDS = 75
TOOLCHAIN_METADATA_BYTES = 65536
TOOLCHAIN_ASSUMPTIONS = [
    'Trusted preinstalled isolated hosted runner; image labels alone do not authenticate it.',
    'SDK, linker, resource headers and compiler dylibs are trusted image inputs, not a cryptographic closure inventory.',
    'Root/admin-controlled ancestors and uid 501 Xcode tree are trusted; no hostile same-UID or admin-process guarantee.',
    'Admission is only for this temporary synthetic fixture, never production finalizer or owner runtime acceptance.']
COMPILER_DIAGNOSTIC_BYTES = 512 * 1024 * 1024
COMPILER_DIAGNOSTIC_SECONDS = 30
DESCRIPTOR_DIAGNOSTIC_SECONDS = 5
FIXTURE = 'Tests/Fixtures/runtime_finalizer_canary.c'
CHECKPOINT = b'dot test-only primitive checkpoint v1\n'
PAYLOAD = b'dot test-only primitive payload v1\n'
COMMIT = b'dot test-only primitive commit v1\n'
CRASHES = {'crash_after_write': 81, 'crash_after_publish': 82, 'crash_after_commit': 83}
GATES = ('fixture_build', 'process_creation', 'process_lifecycle', 'nofollow_metadata',
         'descriptor_inspection', 'system_availability', 'transaction_primitives')


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def raw_record(data):
    return {'bytes': len(data), 'sha256': m.digest(data),
            'base64': base64.b64encode(data).decode('ascii')}


def source_pin(path):
    raw = path.read_bytes()
    return {'bytes': len(raw), 'sha256': m.digest(raw)}


class Receipt:
    def __init__(self):
        self.bytes = 0
        self.gates = {}

    def emit(self, event, **fields):
        check(not {'schema_version', 'kind', 'scope', 'production_acceptance',
                   'owner_runtime_acceptance', 'event'} & fields.keys(), 'reserved receipt field')
        value = {'schema_version': 1, 'kind': 'runtime_finalizer_capability_canary',
                 'scope': 'temporary_synthetic_fixture_only', 'production_acceptance': False,
                 'owner_runtime_acceptance': False, 'event': event, **fields}
        raw = m.canonical(value)
        check(self.bytes + len(raw) <= RECEIPT_BYTES, 'canary receipt byte bound')
        self.bytes += len(raw)
        print(raw.decode('utf-8'), end='', flush=True)

    def gate(self, name, operation):
        try:
            details = operation()
        except Exception as error:
            self.gates[name] = 'fail'
            self.emit('gate', gate=name, status='fail', error=str(error)[:2000],
                      error_type=type(error).__name__, code=getattr(error, 'code', None))
            return False
        self.gates[name] = 'pass'
        self.emit('gate', gate=name, status='pass', details=details)
        return True


def make_context():
    bounds = json.loads((ROOT / m.POLICY_PATH).read_bytes())['bounds']
    bounds.update(portable_operation_seconds=TOTAL_SECONDS - 10,
                  native_static_total_seconds=60, native_command_seconds=10,
                  native_command_output_bytes=OUTPUT_BYTES)
    return SimpleNamespace(bounds=bounds, budget=m.Budget(bounds), phase='native', sources={
        'scripts/reconstruct_runtime_payload.py': source_pin(FINALIZER),
        'Resources/Runtime/dot_process.py': source_pin(ROOT / 'Resources/Runtime/dot_process.py')})


def completed(result, expected=0):
    check(result['reason'] is None, 'command resource failure: ' + str(result['reason']))
    check(result['cleanup']['complete'] is True
          and result['cleanup']['remaining_owned_processes'] == 0
          and result['cleanup']['open_output_pipes'] == 0, 'actual child cleanup incomplete')
    check(type(result['returncode']) is int and result['returncode'] == expected,
          'unexpected command exit: ' + str(result['returncode']))


def run(context, receipt, label, argv, *, pass_fds=(), expected=0, seconds=COMMAND_SECONDS):
    context.budget.check()
    result = m._native_run_bounded(argv, min(context.budget.deadline, time.monotonic() + seconds),
                                   pass_fds=pass_fds, env=m._NS_ENV, cap=OUTPUT_BYTES)
    receipt.emit('command', label=label, result={
        **{key: value for key, value in result.items() if key not in ('stdout', 'stderr')},
        'stdout': raw_record(result['stdout']), 'stderr': raw_record(result['stderr'])})
    completed(result, expected)
    check(re.search(rb'(?im)(^|\s)warning:|xcodebuild: WARNING:',
                    result['stdout'] + b'\n' + result['stderr']) is None, 'command emitted warning diagnostic')
    return result


def toolchain_configuration(receipt):
    """Bounded observations of two fixed paths, never command-selection input."""
    paths = {}
    for role, path in (('compiler', CLANG), ('sdk', SDK)):
        item = {'configured': path, 'resolved': None, 'resolution_error': None}
        try:
            resolved = str(Path(path).resolve(strict=True))
            item.update(resolved=resolved[:4096], path_truncated=len(resolved) > 4096)
        except (OSError, RuntimeError) as error:
            item['resolution_error'] = {'type': type(error).__name__, 'errno': getattr(error, 'errno', None),
                                        'message': str(error)[:512]}
        paths[role] = item
    receipt.emit('toolchain_configuration', paths=paths, hosted_image={
        name: os.environ.get(name, '')[:256] for name in ('ImageOS', 'ImageVersion', 'RUNNER_OS', 'RUNNER_ARCH')})


def toolchain_fd_path(fd):
    """Read-only diagnostic; its result can never authorize a toolchain.

    Apple bsd/sys/fcntl.h: F_GETPATH=50; bsd/sys/param.h maps MAXPATHLEN to
    PATH_MAX, and bsd/sys/syslimits.h fixes PATH_MAX=1024. fcntl(2) requires
    that full buffer. CPython 3.13 fcntl.fcntl(bytes) passes its address and
    returns exactly the buffer length. See the official sources:
    https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/fcntl.h
    https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/param.h
    https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/syslimits.h
    https://docs.python.org/3.13/library/fcntl.html
    """
    if sys.platform != 'darwin':
        return {'fd_path': None, 'fd_path_error': {'type': 'unsupported_platform', 'errno': None}}
    try:
        raw = fcntl.fcntl(fd, 50, b'\0' * 1024)
        if type(raw) is not bytes or len(raw) != 1024 or b'\0' not in raw:
            raise ValueError('invalid bounded F_GETPATH buffer')
        path = raw.split(b'\0', 1)[0].decode('utf-8', 'strict')
        if not path.startswith('/'):
            raise ValueError('nonabsolute F_GETPATH diagnostic')
        return {'fd_path': path, 'fd_path_error': None}
    except (OSError, ValueError) as error:
        return {'fd_path': None, 'fd_path_error': {'type': type(error).__name__,
                'errno': getattr(error, 'errno', None), 'message': str(error)[:256]}}


def toolchain_node(info, path):
    return {'held_path': str(path)[:4096], 'path_truncated': len(str(path)) > 4096,
            'uid': info.st_uid, 'gid': info.st_gid, 'mode': format(stat.S_IMODE(info.st_mode), '04o'),
            'st_mode': info.st_mode, 'device': info.st_dev, 'inode': info.st_ino}


def toolchain_owner(info, path):
    """Only the fixed app admits its recorded installer UID, never arbitrary user tools."""
    inside = Path(path).is_relative_to(Path(XCODE))
    if inside:
        return info.st_uid in (0, 501) and not info.st_mode & 0o7022
    # /Applications is root:admin 0775 in the observed hosted image. Retain the
    # original root-owned/non-world-writable external-ancestor predicate.
    return info.st_uid == 0 and not info.st_mode & 0o002


@contextlib.contextmanager
def trusted_toolchain(path, receipt):
    """Hold no-follow edges throughout signing/build; reject aliases and mutations."""
    check(path in (CLANG, SDK, XCODE_VERSION), 'unconfigured toolchain path')
    resolved = Path(path).resolve(strict=True)
    check(resolved == Path(path), 'toolchain aliases are not admitted')
    check(resolved.is_relative_to(Path(XCODE)), 'toolchain escaped fixed Xcode')
    directory = path == SDK
    with m.Root(resolved if directory else resolved.parent) as root:
        def snapshot(phase):
            root.check()
            ancestors = []
            held_path = Path('/')
            for index, fd in enumerate(root.fds):
                if index:
                    held_path /= root.path.parts[index]
                info = os.fstat(fd)
                observation = {**toolchain_node(info, held_path), **toolchain_fd_path(fd)}
                receipt.emit('toolchain_node', role='ancestor', phase=phase, configured=path,
                             resolved=str(resolved), node=observation)
                check(toolchain_owner(info, held_path),
                      'untrusted toolchain ancestry: ' + json.dumps(observation, sort_keys=True))
                ancestors.append(list(m.directory_identity(info)))
            info = os.fstat(root.fd) if directory else os.stat(
                resolved.name, dir_fd=root.fd, follow_symlinks=False)
            observation = toolchain_node(info, resolved)
            receipt.emit('toolchain_node', role='target_nofollow_stat', phase=phase, configured=path,
                         resolved=str(resolved), node=observation)
            check((stat.S_ISDIR(info.st_mode) if directory else
                   stat.S_ISREG(info.st_mode) and info.st_nlink == 1)
                  and toolchain_owner(info, resolved),
                  'untrusted toolchain node: ' + json.dumps(observation, sort_keys=True))
            root.check()
            return {'ancestors': ancestors, 'target': list(m.identity(info))}

        before = snapshot('before')
        try:
            yield str(resolved), root
        finally:
            if not isinstance(sys.exception(), CanaryDeadline):
                check(snapshot('after') == before, 'toolchain metadata changed during fixture build')


@contextlib.contextmanager
def fixture_toolchain(context, receipt):
    """Test-only exception for the exact observed, trusted hosted Xcode image.

    Apple's TN3127 requires evaluating anchor apple plus the intended identifier;
    displayed Authority/Identifier text is not signature verification. The hash
    pins the observed compiler, not the un-inventoried SDK/linker/dylib closure.
    https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
    https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md
    """
    check(all(os.environ.get(key) == value for key, value in HOSTED_IMAGE.items()),
          'unsupported hosted toolchain image')
    deadline = min(context.budget.deadline, time.monotonic() + TOOLCHAIN_POLICY_SECONDS)

    def bounded():
        context.budget.check()
        check(time.monotonic() < deadline, 'fixture toolchain policy deadline exceeded')

    budget = SimpleNamespace(check=bounded)
    with trusted_toolchain(CLANG, receipt) as (compiler, compiler_root), \
            trusted_toolchain(SDK, receipt) as (sdk, sdk_root), \
            trusted_toolchain(XCODE_VERSION, receipt) as (version, version_root):
        def file_snapshot(root, name, maximum, collect=False):
            bounded()
            root.check()
            info = os.stat(name, dir_fd=root.fd, follow_symlinks=False)
            check(toolchain_owner(info, root.path / name), 'untrusted toolchain metadata owner/mode')
            row, data = m.regular_at(root.fd, name, budget, collect=collect, maximum=maximum)
            m.same_node(info, os.stat(name, dir_fd=root.fd, follow_symlinks=False))
            root.check()
            return {'identity': list(m.identity(info)), **row}, data

        def snapshot(phase):
            compiler_row, _ = file_snapshot(compiler_root, Path(compiler).name, COMPILER_DIAGNOSTIC_BYTES)
            sdk_row, sdk_data = file_snapshot(sdk_root, 'SDKSettings.json', TOOLCHAIN_METADATA_BYTES, True)
            version_row, version_data = file_snapshot(version_root, Path(version).name, TOOLCHAIN_METADATA_BYTES, True)
            result = {'compiler': compiler_row, 'sdk_settings': sdk_row, 'xcode_version': version_row}
            receipt.emit('fixture_toolchain_snapshot', phase=phase, nodes=result)
            check(all(compiler_row[key] == value for key, value in COMPILER_PIN.items()),
                  'unsupported compiler bytes/hash')
            check(m.strict_json(sdk_data).get('Version') == '26.2', 'unsupported fixed SDK version')
            metadata = plistlib.loads(version_data)
            check(type(metadata) is dict and metadata.get('CFBundleShortVersionString') == '26.3'
                  and metadata.get('ProductBuildVersion') == '17C529', 'unsupported fixed Xcode version/build')
            return result

        before = snapshot('before')
        try:
            bounded()
            run(context, receipt, 'fixture_compiler_identity', ['/usr/bin/codesign', '--verify', '--strict',
                '--verbose=4', '--test-requirement', COMPILER_REQUIREMENT, compiler],
                seconds=min(10, deadline - time.monotonic()))
            check(snapshot('after_signature') == before, 'toolchain changed during signature verification')
            receipt.emit('fixture_toolchain_policy', status='admitted', compiler_requirement=COMPILER_REQUIREMENT,
                         compiler_pin=COMPILER_PIN, hosted_image=HOSTED_IMAGE,
                         authorizes_synthetic_fixture_build=True, assumptions=TOOLCHAIN_ASSUMPTIONS)
            yield compiler, sdk, deadline
        finally:
            if not isinstance(sys.exception(), CanaryDeadline):
                check(snapshot('after_build') == before, 'toolchain changed during fixture build')


def compiler_identity_diagnostic(context, receipt):
    """Read-only, source-bound evidence before the separate fixture admission gate.

    No caller-selected path or environment value selects an executable. The
    compiler is only read, never executed by this diagnostic. Display output is
    retained verbatim; neither a displayed identifier/Authority nor an Apple
    anchor result is a compiler identity policy or permission to build.
    Apple TN3127 documents display of the actual designated requirement and
    '=anchor apple' (distinct from 'anchor apple generic') evaluation:
    https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements
    """
    deadline = min(context.budget.deadline, time.monotonic() + COMPILER_DIAGNOSTIC_SECONDS)

    def bounded():
        context.budget.check()
        check(time.monotonic() < deadline, 'compiler diagnostic deadline exceeded')

    budget = SimpleNamespace(check=bounded)
    try:
        bounded()
        resolved = Path(CLANG).resolve(strict=True)
        check(str(resolved).startswith(DEVELOPER + '/'), 'compiler diagnostic escaped fixed Xcode')
        check(len(str(resolved).encode('utf-8')) <= 4096, 'compiler diagnostic path byte bound')
        with m.Root(resolved.parent) as root:
            def snapshot():
                bounded()
                root.check()
                check(Path(CLANG).resolve(strict=True) == resolved, 'configured compiler resolution changed')
                info = os.stat(resolved.name, dir_fd=root.fd, follow_symlinks=False)
                row, _ = m.regular_at(root.fd, resolved.name, budget,
                                      maximum=COMPILER_DIAGNOSTIC_BYTES)
                m.same_node(info, os.stat(resolved.name, dir_fd=root.fd, follow_symlinks=False))
                root.check()
                return {**toolchain_node(info, resolved), 'bytes': row['bytes'], 'sha256': row['sha256'],
                        'nlink': info.st_nlink, 'mtime_ns': info.st_mtime_ns, 'ctime_ns': info.st_ctime_ns,
                        'identity': list(m.identity(info))}

            before = snapshot()
            receipt.emit('compiler_identity_snapshot', phase='before', configured=CLANG,
                         node=before, authorizes_build=False)
            try:
                for label, argv in (
                    ('compiler_signature_display', ['/usr/bin/codesign', '-d', '--verbose=4',
                                                    '--requirements', '-', str(resolved)]),
                    ('compiler_signature_apple_anchor', ['/usr/bin/codesign', '--verify', '--strict',
                                                        '--verbose=4', '--test-requirement',
                                                        '=anchor apple', str(resolved)])):
                    bounded()
                    root.check()
                    check(Path(CLANG).resolve(strict=True) == resolved, 'configured compiler resolution changed')
                    current = os.stat(resolved.name, dir_fd=root.fd, follow_symlinks=False)
                    check(list(m.identity(current)) == before['identity'], 'compiler metadata changed before inspection')
                    run(context, receipt, label, argv, seconds=min(10, deadline - time.monotonic()))
            finally:
                after = snapshot()
                receipt.emit('compiler_identity_snapshot', phase='after', configured=CLANG,
                             node=after, authorizes_build=False)
                check(before == after, 'compiler changed during signature inspection')
        receipt.emit('compiler_identity_diagnostic', status='observed', configured=CLANG,
                     authorizes_build=False, compiler_identity_policy_applied=False)
    except Exception as error:
        receipt.emit('compiler_identity_diagnostic', status='fail', configured=CLANG,
                     authorizes_build=False, compiler_identity_policy_applied=False,
                     error_type=type(error).__name__, error=str(error)[:2000])
    # Deliberately no success value. Only fixture_toolchain may admit the build.


def build(context, receipt, base):
    toolchain_configuration(receipt)
    compiler_identity_diagnostic(context, receipt)
    source = base / 'fixture.c'
    source.write_bytes((ROOT / FIXTURE).read_bytes()); source.chmod(0o600)
    payload = base / 'payload'; payload.mkdir(mode=0o700)
    binary = payload / 'canary'
    with fixture_toolchain(context, receipt) as (compiler, sdk, deadline):
        run(context, receipt, 'compile_fixture', [compiler, '--no-default-config', '-arch', 'arm64', '-isysroot', sdk,
            '-mmacosx-version-min=15.0', '-std=c11', '-O0', '-Wall', '-Wextra', '-Werror',
            str(source), '-o', str(binary)], seconds=min(30, deadline - time.monotonic()))
    binary.chmod(0o700)
    run(context, receipt, 'adhoc_sign_fixture', ['/usr/bin/codesign', '--force', '--sign', '-',
        '--timestamp=none', '--identifier', 'org.dot.test.runtime-finalizer-canary', str(binary)])
    return {'source': source_pin(source), 'signed_fixture': source_pin(binary),
            'compiler': compiler, 'sdk': sdk, 'signing': 'temporary_ad_hoc_only'}


def validate_creation(result, denied):
    completed(result)
    check(result['stderr'] == b'', 'unexpected process-control stderr')
    lines = result['stdout'].decode('ascii').splitlines()
    if denied:
        check(len(lines) == 2 and re.fullmatch(r'FORK_DENIED (1|13)', lines[0])
              and re.fullmatch(r'SPAWN_DENIED (1|13)', lines[1]),
              'fork/posix_spawn did not both return explicit permission denial')
    else:
        # sysctl output precedes the parent stdio buffer's two control records.
        check(lines == ['1', 'FORK_OK 17', 'SPAWN_OK 0'], 'positive fork/spawn controls failed')
    return lines


def creation(context, receipt, base):
    binary = str(base / 'payload/canary')
    positive = run(context, receipt, 'creation_positive', [binary, 'control'], seconds=10)
    control = validate_creation(positive, False)
    profile = m._ns_profile(str(base / 'payload'))
    denied = run(context, receipt, 'creation_exact_production_profile', [binary, 'deny', profile], seconds=10)
    negative = validate_creation(denied, True)
    return {'control': control, 'denial': negative, 'profile_sha256': m.digest(profile.encode()),
            'profile_is_unmodified_production': True, 'child_executable': '/usr/sbin/sysctl'}


def wait_until(condition, deadline, label):
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.01)
    raise AssertionError('bounded lifecycle observation expired: ' + label)


def lifecycle(context, receipt, base):
    """Actual production-helper proof controls; not a replacement process runner.

    The fixture modes contain no exec or process-group escape. The sole possible
    descendant has a fixed ten-second lifetime. Keep the leader unreaped until
    the one group-kill attempt, then observe actual wait/group disappearance.
    Portable injected syscall-failure tests live with the production helper;
    this gate does not pretend to manufacture a real libproc syscall failure.
    """
    helper = getattr(m, '_native_darwin_exited_singleton', None)
    check(callable(helper), 'reviewed Darwin singleton-proof API required')
    cases = []
    for mode, expected in (('lifecycle-exit', True), ('lifecycle-live', False),
                           ('lifecycle-mixed', False)):
        context.budget.check()
        output = base / (mode + '.stdout')
        error_output = base / (mode + '.stderr')
        with output.open('xb') as stdout, error_output.open('xb') as stderr:
            child = subprocess.Popen([str(base / 'payload/canary'), mode],
                                     stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                                     close_fds=True, start_new_session=True, env=m._NS_ENV)
            observed = None
            kill_errno = None
            child_status = None
            cleanup_error = None
            try:
                deadline = min(context.budget.deadline, time.monotonic() + 3)
                wait_until(lambda: output.stat().st_size > 0, deadline, mode + ' output')
                if mode != 'lifecycle-live':
                    wait_until(lambda: m._native_child_exited(child), deadline, mode + ' exit')
                else:
                    check(m._native_child_exited(child) is False, 'live control exited early')
                if mode == 'lifecycle-mixed':
                    raw = output.read_bytes()
                    check(re.fullmatch(rb'MIXED_CHILD [1-9][0-9]*\n', raw), 'mixed child identity missing')
                    descendant = int(raw.split()[1])
                    check(os.getpgid(descendant) == child.pid, 'live child left owned group')
                    os.kill(descendant, 0)  # Read-only liveness check, never a fake child.
                observed = helper(child)
                check(observed is expected, 'Darwin singleton proof accepted/rejected wrong actual membership')
            finally:
                # All fixture children are bounded and remain in this owned group.
                # This is test teardown, not an alternate production runner.
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except OSError as error:
                    kill_errno = error.errno
                    if error.errno != errno.ESRCH:
                        if not (error.errno == errno.EPERM and helper(child) is True):
                            cleanup_error = 'unproven group kill failure: ' + str(error.errno)
                try:
                    child_status = child.wait(timeout=12)
                except subprocess.TimeoutExpired:
                    cleanup_error = 'fixture leader did not terminate within hard lifetime'
                gone = False
                deadline = min(context.budget.deadline, time.monotonic() + 12)
                while time.monotonic() < deadline:
                    try:
                        os.killpg(child.pid, 0)
                    except ProcessLookupError:
                        gone = True
                        break
                    except PermissionError:
                        break
                    time.sleep(0.01)
                if not gone:
                    cleanup_error = 'owned fixture process group still visible'
                receipt.emit('lifecycle', case=mode, singleton_proof=observed, expected_proof=expected,
                             kill_errno=kill_errno, returncode=child_status,
                             group_gone=gone, cleanup_error=cleanup_error,
                             stdout=raw_record(output.read_bytes()), stderr=raw_record(error_output.read_bytes()))
                check(cleanup_error is None, str(cleanup_error))
                check(helper(child) is False, 'already reaped child accepted as singleton proof')
            check(error_output.read_bytes() == b'', 'unexpected lifecycle stderr')
            expected_status = -signal.SIGKILL if mode == 'lifecycle-live' else 0
            check(child_status == expected_status, 'unexpected actual lifecycle exit status')
            if mode != 'lifecycle-mixed':
                expected_output = b'LEADER_LIVE\n' if mode == 'lifecycle-live' else b'LEADER_EXIT\n'
                check(output.read_bytes() == expected_output, 'wrong actual lifecycle control output')
            cases.append({'case': mode, 'singleton_proof': observed, 'actual_group_gone': gone})
    # This is a real ECHILD/non-child observation, not a substituted process API.
    nonchild = SimpleNamespace(pid=os.getpid(), returncode=None)
    check(helper(nonchild) is False, 'non-child process accepted as singleton proof')
    return {'cases': cases, 'nonchild_rejected': True, 'reaped_children_rejected': True,
            'enumeration_failure_injected': False,
            'enumeration_failure_coverage': 'separate portable production-helper adversarial tests'}


def expect_rejected(operation, message, code=None):
    try:
        operation()
    except m.Rejected as error:
        check(message in str(error) and (code is None or error.code == code),
              'wrong rejection: ' + str(error))
        return {'reason': str(error), 'code': error.code}
    raise AssertionError('required rejection did not occur: ' + message)


def fixture_xattr(path, *, remove=False):
    """Author/remove only this canary's fixed temporary test attribute.

    CPython's os xattr helpers are Linux-only. Use the Darwin <sys/xattr.h>
    signatures: setxattr(path, name, value, size, uint32_t position, int options)
    and removexattr(path, name, int options). XATTR_NOFOLLOW is 0x0001.
    This only prepares the fixture; the production no-follow reader determines
    whether the real attribute is present. Missing APIs or errno failures fail.
    """
    m.require(sys.platform == 'darwin', 'Darwin fixture xattr API required', m.UNSUPPORTED)
    library = ctypes.CDLL('/usr/lib/libSystem.B.dylib', use_errno=True)
    encoded = os.fsencode(path)
    name, value = b'com.dot.runtime-canary', b'test-only'
    if remove:
        operation = library.removexattr
        operation.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
        operation.restype = ctypes.c_int
        result = operation(encoded, name, 1)
    else:
        operation = library.setxattr
        operation.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
                              ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
        operation.restype = ctypes.c_int
        result = operation(encoded, name, value, len(value), 0, 1)
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, 'Darwin fixture xattr ' + ('removal' if remove else 'setup') + ' failed',
                      os.fspath(path))


def metadata(context, receipt, base):
    path = base / 'metadata'; path.mkdir(mode=0o700)
    directory = path / 'directory'; directory.mkdir(mode=0o700)
    target = directory / 'file'; target.write_bytes(b'fixture'); target.chmod(0o600)
    (path / 'link').symlink_to('directory/file')
    rows = m.tree(path, context.budget)
    with m.Root(path) as root:
        clean = m._native_empty_xattrs(context, root, rows)
        fixture_xattr(target)
        # Inspecting only the link must not see its target's deliberately set xattr.
        link = [row for row in rows if row['path'] == 'link']
        nofollow = m._native_empty_xattrs(context, root, link)
        target_rejection = expect_rejected(lambda: m._native_empty_xattrs(context, root, rows),
                                          'UNREVIEWED_NATIVE_METADATA', m.INVALID)
        fixture_xattr(target, remove=True)
        fixture_xattr(directory)
        directory_rejection = expect_rejected(lambda: m._native_empty_xattrs(context, root, rows),
                                             'UNREVIEWED_NATIVE_METADATA', m.INVALID)
        fixture_xattr(directory, remove=True)
        check(clean == m._native_empty_xattrs(context, root, rows), 'empty metadata replay changed')
        expect_rejected(lambda: m.regular_at(root.fd, 'link', context.budget), 'single-link regular file')
    alias = base / 'metadata-alias'; alias.symlink_to('metadata')
    expect_rejected(lambda: m.Root(alias), 'symlink/non-directory ancestor')
    return {'empty_rows': clean, 'symlink_nofollow_with_nonempty_target': nofollow,
            'file_rejection': target_rejection, 'directory_rejection': directory_rejection}


def descriptor_identity_diagnostic(context, receipt, base):
    """Read only the six configured nodes; observations never change admission.

    The production toolset can reject before any command receipt exists. Retain
    no-follow metadata and, for regular nodes only, metadata from an open
    no-follow descriptor. Do not read bytes, resolve aliases, or execute tools.
    Multiple links are observed here, never accepted by regular_at/toolset.
    """
    deadline = min(context.budget.deadline, time.monotonic() + DESCRIPTOR_DIAGNOSTIC_SECONDS)
    targets = [('synthetic_canary', base / 'payload/canary')]
    targets.extend(('fixed_tool_' + name, Path(path)) for name, path in m._NS_TOOLS.items())
    check(len(targets) == 6, 'descriptor diagnostic fixed target count changed')

    def bounded():
        context.budget.check()
        check(time.monotonic() < deadline, 'descriptor diagnostic deadline exceeded')

    def node(info, path):
        kind = next((name for name, predicate in (
            ('regular', stat.S_ISREG), ('directory', stat.S_ISDIR), ('symlink', stat.S_ISLNK),
            ('fifo', stat.S_ISFIFO), ('socket', stat.S_ISSOCK), ('character', stat.S_ISCHR),
            ('block', stat.S_ISBLK)) if predicate(info.st_mode)), 'unknown')
        return {**toolchain_node(info, path), 'file_type': kind, 'nlink': info.st_nlink,
                'bytes': info.st_size, 'mtime_ns': info.st_mtime_ns, 'ctime_ns': info.st_ctime_ns}

    for role, path in targets:
        bounded()
        observation = {'role': role, 'configured': str(path), 'nofollow': None,
                       'held': None, 'after': None, 'authorizes_inspection': False}
        try:
            with m.Root(path.parent) as root:
                root.check()
                before = os.stat(path.name, dir_fd=root.fd, follow_symlinks=False)
                observation['nofollow'] = node(before, path)
                if stat.S_ISREG(before.st_mode):
                    fd = os.open(path.name, m.FLAGS, dir_fd=root.fd)
                    try:
                        held = os.fstat(fd)
                        observation['held'] = {**node(held, path), **toolchain_fd_path(fd)}
                        m.same_node(before, held)
                        m.same_node(before, os.fstat(fd))
                    finally:
                        os.close(fd)
                after = os.stat(path.name, dir_fd=root.fd, follow_symlinks=False)
                observation['after'] = node(after, path)
                m.same_node(before, after)
                root.check()
            observation['status'] = 'observed'
        except Exception as error:
            observation.update(status='fail', error_type=type(error).__name__,
                               errno=getattr(error, 'errno', None), code=getattr(error, 'code', None),
                               error=str(error)[:512])
        receipt.emit('descriptor_identity', **observation)
        bounded()
    # No return value, approval or substitute toolset; the original gate follows.


def static_inspection(context, receipt, base):
    descriptor_identity_diagnostic(context, receipt, base)
    path = base / 'payload'
    rows = m.tree(path, context.budget)
    receipt.emit('descriptor_payload_tree', status='observed', entries=len(rows))
    with m.Root(path) as root:
        with contextlib.closing(m._NativeToolset(context, root, rows)) as tools:
            try:
                host = tools.call('host_arm64', '.')
                check(host[:2] == (b'1\n', b''), 'native arm64 host required')
                row = next(row for row in rows if row['path'] == 'canary')
                with m._ns_open_object(context, root, row) as (fd, magic):
                    check(magic in m._NS_MAGIC, 'fixture is not Mach-O')
                    outputs = {role: tools.call(role, 'canary', descriptor=fd) for role in
                               ('lipo', 'otool_libraries', 'otool_loads', 'codesign_display',
                                'codesign_entitlements', 'codesign_verify')}
                def output(role):
                    return outputs[role][:2]
                architectures = m._parse_native_lipo(*output('lipo'))
                check(architectures == ['arm64'], 'fixture architecture is not exact arm64')
                target = outputs['otool_loads'][2]
                facts = m._parse_native_otool_loads(*output('otool_loads'), target, architectures)
                libraries = m._parse_native_otool_libraries(*output('otool_libraries'), target, architectures)
                m._ns_check_otool_agreement(facts, libraries)
                signature = m._parse_native_codesign_display(*output('codesign_display'), target,
                                                             (str(path / 'canary'),))
                signature['entitlements'] = m._parse_native_entitlements(*output('codesign_entitlements'), target)
                m._parse_native_codesign_verify(*output('codesign_verify'), target)
                check(signature['ad_hoc'] and signature['team_id'] is None
                      and signature['entitlements'] == {}, 'unexpected fixture signing identity/entitlements')
                obj = {**m._ns_target_pin(rows, 'canary'), 'architectures': architectures,
                       **facts, 'signature': signature}
                contexts = [{'id': 'synthetic-canary', 'executable': 'canary', 'loaded_objects': ['canary']}]
                roots = list(m._NS_SYSTEM_ROOTS)
                edges = m._native_resolved_edges(rows, [obj], contexts, roots, context.budget)
                start, started = time.monotonic(), m.datetime.datetime.now(m.datetime.timezone.utc).isoformat()
                targets = m._native_system_targets(context, [obj], contexts, edges, roots)
                event, name, raw = m._ns_system_event(context, targets, start, started)
                tools.events.append(event); tools.artifacts[name] = raw
                inventory = {'objects': [obj], 'code_bundles': [], 'launch_contexts': contexts,
                             'system_roots': roots, 'system_targets': targets}
                # These expectations are ONLY freshly observed synthetic fixture facts.
                # No source-owned approval/acceptance writer is called or created.
                parsed = m._parse_native_static_evidence(context, rows, inventory, tools.events, tools.artifacts)
                fresh = m._verify_native_static(context, root, inventory)
                receipt.emit('fresh_static_capture', tool_events=fresh['tool_events'],
                             raw_artifacts={name: raw_record(raw) for name, raw in fresh['raw_artifacts'].items()})
                check(parsed['parsed_static_facts']['native_objects'] == fresh['native_objects'],
                      'actual repeated fixture inspection differs')
                return {'native_objects': fresh['native_objects'], 'system_targets': fresh['system_targets'],
                        'metadata_before': fresh['metadata_empty_before'],
                        'metadata_after': fresh['metadata_empty_after'], 'code_bundles_exercised': False}
            except Exception as error:
                capture = getattr(error, 'native_static_capture', None)
                if capture:
                    receipt.emit('failed_fresh_static_capture', tool_events=capture['tool_events'],
                                 raw_artifacts={name: raw_record(raw) for name, raw in capture['raw_artifacts'].items()})
                raise
            finally:
                receipt.emit('descriptor_static_capture', tool_events=tools.events,
                             raw_artifacts={name: raw_record(raw) for name, raw in tools.artifacts.items()})


def system_availability(context, receipt, base):
    del receipt, base
    present, cache_uuid = m._ns_system_cache('/usr/lib/libSystem.B.dylib')
    check(present and re.fullmatch('[0-9a-f]{32}', cache_uuid), 'actual libSystem cache proof absent')
    missing = '/usr/lib/dot-runtime-finalizer-canary-does-not-exist.dylib'
    absent, same_uuid = m._ns_system_cache(missing)
    check(not absent and same_uuid == cache_uuid, 'dyld negative control/identity failed')
    # Minimal test-only request graph for actual system-target API validation.
    objects = [{'path': 'canary', 'architectures': ['arm64']}]
    contexts = [{'id': 'synthetic-canary', 'executable': 'canary', 'loaded_objects': ['canary']}]
    def lookup(path):
        edges = [{'context': 'synthetic-canary', 'target_kind': 'system', 'target': path}]
        return m._native_system_targets(context, objects, contexts, edges, list(m._NS_SYSTEM_ROOTS))
    targets = lookup('/usr/lib/libSystem.B.dylib')
    missing_rejection = expect_rejected(lambda: lookup(missing), 'unresolved system dependency', m.INVALID)
    return {'targets': targets, 'missing_rejection': missing_rejection,
            'physical_system_dylib_branch_exercised': targets[0]['availability'] == 'file'}


def read_exact(fd, name, raw, budget):
    _, found = m.regular_at(fd, name, budget, {'bytes': len(raw), 'sha256': m.digest(raw)}, True)
    check(found == raw, 'test-only transaction byte mismatch')


def exists(fd, name):
    try:
        os.stat(name, dir_fd=fd, follow_symlinks=False)
        return True
    except FileNotFoundError:
        return False


def transaction_worker(fd, mode):
    """Finite internal worker over an inherited private directory descriptor."""
    check(mode in {*CRASHES, 'resume', 'contend'}, 'unknown fixed transaction mode')
    info = os.fstat(fd)
    check(stat.S_ISDIR(info.st_mode) and stat.S_IMODE(info.st_mode) == 0o700
          and info.st_uid == os.geteuid(), 'test-only private directory required')
    context = make_context()
    read_exact(fd, 'checkpoint', CHECKPOINT, context.budget)
    lock = os.open('checkpoint', m.FLAGS, dir_fd=fd)
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            check(mode == 'contend', 'unexpected transaction contention')
            print('LOCK_BUSY', flush=True)
            return 0
        check(mode != 'contend', 'held lock did not exclude separate process')
        if not exists(fd, 'published'):
            if not exists(fd, 'pending'):
                m.write_new(fd, 'pending', PAYLOAD)
            read_exact(fd, 'pending', PAYLOAD, context.budget)
            if mode == 'crash_after_write': os._exit(CRASHES[mode])
            m.no_replace(fd, 'pending', 'published')
        read_exact(fd, 'published', PAYLOAD, context.budget)
        if mode == 'crash_after_publish': os._exit(CRASHES[mode])
        if not exists(fd, 'commit'):
            if not exists(fd, 'commit.pending'):
                m.write_new(fd, 'commit.pending', COMMIT)
            read_exact(fd, 'commit.pending', COMMIT, context.budget)
            m.no_replace(fd, 'commit.pending', 'commit')
        read_exact(fd, 'commit', COMMIT, context.budget)
        if mode == 'crash_after_commit': os._exit(CRASHES[mode])
        print('REPLAY_IDENTICAL', flush=True)
        return 0
    finally:
        os.close(lock)


def transactions(context, receipt, base):
    outcomes = []
    for mode, exit_status in CRASHES.items():
        path = base / mode; path.mkdir(mode=0o700)
        with m.Root(path) as root:
            m.write_new(root.fd, 'checkpoint', CHECKPOINT)
            command = [str(Path(sys.executable).resolve()), '-I', '-B', str(Path(__file__).resolve()),
                       '--transaction-worker', str(root.fd)]
            lock = os.open('checkpoint', m.FLAGS, dir_fd=root.fd)
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                result = run(context, receipt, mode + '_contention', command + ['contend'], pass_fds=(root.fd,))
                check(result['stdout'] == b'LOCK_BUSY\n', 'missing actual lock contention')
            finally:
                os.close(lock)
            run(context, receipt, mode, command + [mode], pass_fds=(root.fd,), expected=exit_status)
            check(exists(root.fd, 'commit') == (mode == 'crash_after_commit'), 'wrong crash commit boundary')
            replay = run(context, receipt, mode + '_resume', command + ['resume'], pass_fds=(root.fd,))
            check(replay['stdout'] == b'REPLAY_IDENTICAL\n', 'missing resume result')
            before = {name: m.identity(os.stat(name, dir_fd=root.fd, follow_symlinks=False))
                      for name in ('checkpoint', 'published', 'commit')}
            replay = run(context, receipt, mode + '_repeat', command + ['resume'], pass_fds=(root.fd,))
            check(replay['stdout'] == b'REPLAY_IDENTICAL\n', 'missing identical retry result')
            check(before == {name: m.identity(os.stat(name, dir_fd=root.fd, follow_symlinks=False))
                             for name in before}, 'retry replaced or changed committed files')
            m.write_new(root.fd, 'conflict', b'conflict')
            expect_rejected(lambda: m.no_replace(root.fd, 'conflict', 'published'), 'atomic publication refused', m.INVALID)
            read_exact(root.fd, 'published', PAYLOAD, context.budget)
            read_exact(root.fd, 'conflict', b'conflict', context.budget)
            os.mkdir('directory.pending', 0o700, dir_fd=root.fd)
            m.no_replace(root.fd, 'directory.pending', 'directory')
            os.mkdir('directory.conflict', 0o700, dir_fd=root.fd)
            expect_rejected(lambda: m.no_replace(root.fd, 'directory.conflict', 'directory'),
                            'atomic publication refused', m.INVALID)
            root.check()
            outcomes.append({'crash': mode, 'exit_status': exit_status, 'retries': 2,
                             'lock_excluded_competitor': True, 'file_and_directory_conflicts_preserved': True})
    return {'cases': outcomes, 'fsync': 'actual production write_new/no_replace calls completed',
            'power_loss_durability_proven': False, 'production_transaction_exercised': False}


class CanaryDeadline(BaseException):
    pass


def deadline_alarm(signum, frame):
    del signum, frame
    raise CanaryDeadline('whole canary deadline exceeded')


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if len(argv) == 3 and argv[0] == '--transaction-worker':
        check(argv[1].isdigit() and 3 <= int(argv[1]) <= 1_000_000, 'invalid inherited descriptor')
        return transaction_worker(int(argv[1]), argv[2])
    check(not argv, 'no public canary arguments are supported')
    receipt = Receipt()
    receipt.emit('start', platform=sys.platform, architecture=os.uname().machine,
                 python=sys.version, deadline_seconds=TOTAL_SECONDS,
                 sources={name: source_pin(ROOT / name) for name in
                          ('scripts/reconstruct_runtime_payload.py', 'scripts/test_runtime_finalizer_native.py', FIXTURE)})
    if sys.platform != 'darwin' or os.uname().machine != 'arm64':
        receipt.emit('summary', status='fail', error='actual Darwin arm64 host required; no portable substitute', gates={})
        return m.UNSUPPORTED
    previous = signal.signal(signal.SIGALRM, deadline_alarm)
    signal.setitimer(signal.ITIMER_REAL, TOTAL_SECONDS)
    try:
        context = make_context()
        with tempfile.TemporaryDirectory(prefix='dot-finalizer-canary-',
                                         dir=Path(tempfile.gettempdir()).resolve()) as temporary:
            base = Path(temporary)
            built = receipt.gate('fixture_build', lambda: build(context, receipt, base))
            for name, operation, needs_fixture in (
                ('process_creation', creation, True), ('process_lifecycle', lifecycle, True),
                ('nofollow_metadata', metadata, False),
                ('descriptor_inspection', static_inspection, True),
                ('system_availability', system_availability, False),
                ('transaction_primitives', transactions, False)):
                if needs_fixture and not built:
                    receipt.gates[name] = 'fail'
                    receipt.emit('gate', gate=name, status='fail', error='required fixture build failed')
                else:
                    receipt.gate(name, lambda operation=operation: operation(context, receipt, base))
        check(not base.exists(), 'temporary fixture cleanup incomplete')
        passed = set(receipt.gates) == set(GATES) and all(value == 'pass' for value in receipt.gates.values())
        receipt.emit('summary', status='pass' if passed else 'fail', gates=receipt.gates,
                     temporary_tree_removed=True, limitations=[
                         'No genuine owner inventory, model, dynamic harness or production native approval.',
                         'Synthetic thin executable only; no production bundle-layout acceptance.',
                         'Primitive crash replay is not a power-loss or production transaction proof.',
                         *TOOLCHAIN_ASSUMPTIONS])
        return 0 if passed else 1
    except (Exception, CanaryDeadline) as error:
        receipt.emit('summary', status='fail', gates=receipt.gates, error=str(error)[:2000])
        return 1
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


if __name__ == '__main__':
    raise SystemExit(main())
