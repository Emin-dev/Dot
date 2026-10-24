"""Audit S10 (A): the log-upload token file is read only when it is private, and
the token never reaches a command line.

`DotLogSync.swift` is app-only (outside the DotCore SwiftPM target), so its
file check is ported here from the Swift source itself: the conditions of
`tokenFileRefusal` and the `open` flags of `fileToken` are read out of
`src/DotLogSync.swift` and run against real files, so a change to the Swift
logic changes what these tests see. Swift compilation stays in macOS CI.
"""
import errno
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SWIFT = (ROOT / 'src/DotLogSync.swift').read_text()
STORE_SCRIPT = ROOT / 'scripts/store_github_token.sh'
SIGNATURE = 'static func tokenFileRefusal(mode: UInt32, owner: UInt32, currentUser: UInt32) -> String? {'
INTERPOLATED_MODE = r'\(String(mode & 0o777, radix: 8))'


def swift_section(start, end):
    head, found, rest = SWIFT.partition(start)
    if not found:
        raise AssertionError(f'{start!r} is missing from src/DotLogSync.swift')
    return rest.partition(end)[0]


def swift_refusal_rules():
    """The `if <condition> { return "<reason>" }` lines of the Swift function, in order."""
    body = swift_section(SIGNATURE, '\n    }\n')
    rules = re.findall(r'^\s*if (.+?) \{ return "(.*)" \}$', body, re.M)
    if not rules or body.strip().splitlines()[-1].strip() != 'return nil':
        raise AssertionError('tokenFileRefusal no longer has the expected shape')
    for condition, _ in rules:
        # Only names, octal literals, & and != : the same expression in Swift and Python.
        if not re.fullmatch(r'[\sA-Za-z0-9()&!=]+', condition):
            raise AssertionError(f'unsupported condition {condition!r}')
    return rules


def token_file_refusal(mode, owner, current_user):
    """Runs the Swift conditions, unchanged, with Python's identical operators."""
    names = {'mode': mode, 'owner': owner, 'currentUser': current_user}
    for condition, reason in swift_refusal_rules():
        if eval(condition, {'__builtins__': {}}, names):
            return reason.replace(INTERPOLATED_MODE, format(mode & 0o777, 'o'))
    return None


def swift_open_flags():
    match = re.search(r'let fd = Darwin\.open\(url\.path, ([A-Z_ |]+)\)',
                      swift_section('private func fileToken() -> String? {', '\n    }\n'))
    if not match:
        raise AssertionError('fileToken no longer opens the file with explicit flags')
    flags = 0
    for name in match.group(1).split('|'):
        flags |= getattr(os, name.strip())
    return flags


def read_token_file(path):
    """Port of `DotLogSync.fileToken`: returns (token, refusal reason)."""
    try:
        fd = os.open(path, swift_open_flags())
    except OSError as error:
        return None, ('it is a symbolic link' if error.errno == errno.ELOOP else None)
    try:
        info = os.fstat(fd)
        reason = token_file_refusal(info.st_mode, info.st_uid, os.getuid())
        if reason:
            return None, reason
        try:
            value = os.read(fd, 4096).decode('utf-8').strip()
        except UnicodeDecodeError:
            return None, None
        return (value or None), None
    finally:
        os.close(fd)


def scratch(test):
    base = ROOT / '.tmp'
    base.mkdir(exist_ok=True)
    temporary = tempfile.TemporaryDirectory(dir=base)
    test.addCleanup(temporary.cleanup)
    return Path(temporary.name)


class TokenFileTests(unittest.TestCase):
    def setUp(self):
        self.dir = scratch(self)

    def token_file(self, mode, text='  ghp_exampleexampleexample \n', name='github.token'):
        path = self.dir / name
        # A previous case may have left it read-only (0o400): only root could rewrite that.
        path.unlink(missing_ok=True)
        path.write_text(text)
        os.chmod(path, mode)
        return path

    def test_only_a_private_regular_file_is_read(self):
        for mode in (0o600, 0o400, 0o700):
            self.assertEqual(read_token_file(self.token_file(mode)), ('ghp_exampleexampleexample', None), oct(mode))
        for mode, shown in ((0o640, '640'), (0o604, '604'), (0o660, '660'), (0o610, '610'), (0o644, '644')):
            self.assertEqual(read_token_file(self.token_file(mode)),
                             (None, f'group or others can access it (mode {shown})'), oct(mode))
        self.assertEqual(read_token_file(self.token_file(0o600, text=' \n')), (None, None))
        self.assertEqual(read_token_file(self.dir / 'missing.token'), (None, None))

    def test_every_group_or_other_bit_is_refused(self):
        for permissions in range(0o1000):
            reason = token_file_refusal(stat.S_IFREG | permissions, 501, 501)
            self.assertEqual(reason is None, permissions & 0o077 == 0, oct(permissions))

    def test_a_symbolic_link_is_never_followed(self):
        target = self.token_file(0o600, name='elsewhere.token')
        link = self.dir / 'github.token'
        link.symlink_to(target)
        self.assertEqual(read_token_file(link), (None, 'it is a symbolic link'))

    def test_a_directory_or_fifo_is_not_a_token_file(self):
        directory = self.dir / 'github.token'
        directory.mkdir(mode=0o700)
        self.assertEqual(read_token_file(directory), (None, 'it is not a regular file'))
        fifo = self.dir / 'fifo.token'
        os.mkfifo(fifo, 0o600)
        # O_NONBLOCK: opening a FIFO with no writer must not hang the uploader.
        self.assertEqual(read_token_file(fifo), (None, 'it is not a regular file'))

    def test_a_file_owned_by_someone_else_is_refused(self):
        self.assertEqual(token_file_refusal(stat.S_IFREG | 0o600, 0, 501), 'it is not owned by this user')
        if os.geteuid() != 0:
            self.skipTest('changing a file owner needs root')
        path = self.token_file(0o600)
        os.chown(path, 65534, -1)
        self.assertEqual(read_token_file(path), (None, 'it is not owned by this user'))

    def test_swift_checks_the_open_descriptor_before_it_reads_and_logs_no_contents(self):
        body = swift_section('private func fileToken() -> String? {', '\n    }\n')
        self.assertLess(body.index('fstat(fd, &info) == 0'), body.index('Self.tokenFileRefusal('))
        self.assertLess(body.index('refuseTokenFile(reason)\n            return nil'), body.index('handle.read(upToCount: 4096)'))
        self.assertIn('currentUser: getuid())', body)
        token_section = swift_section('    private func token() -> String? {', 'private func keychainToken()')
        self.assertNotIn('String(contentsOf:', token_section)
        self.assertIn('return fileToken()', token_section)
        refusal = swift_section('private func refuseTokenFile(_ reason: String) {', '\n    }\n')
        self.assertEqual(re.findall(r'\\\((.*?)\)', refusal), ['reason'])
        # LogRedaction masks "token is ..." and "token: ...", which would garble the line.
        message = ''.join(re.findall(r'"([^"]*)"', refusal))
        self.assertIsNone(re.search(r'(?i)\btoken\s+(?:is|was)\s|\btoken\s*[:=]', message))


class StoreScriptTests(unittest.TestCase):
    TOKEN = 'ghp_ExampleTokenThatMustNeverReachArgv01'

    def run_script(self, expected):
        work = scratch(self)
        bin_dir = work / 'bin'
        bin_dir.mkdir()
        (bin_dir / 'security').write_text(
            '#!/bin/bash\n'
            'printf "%s\\n" "$*" >> "$ARGV_LOG"\n'
            'case "$1" in\n'
            '  add-generic-password)\n'
            '    [ "${@: -1}" = "-w" ] || exit 64\n'      # -w last: security prompts itself
            '    IFS= read -r first; IFS= read -r again\n'  # stands in for the two hidden prompts
            '    [ "$first" = "$again" ] || exit 1\n'
            '    printf "%s" "$first" > "$KEYCHAIN" ;;\n'
            '  find-generic-password) cat "$KEYCHAIN"; echo ;;\n'
            '  delete-generic-password) rm -f "$KEYCHAIN" ;;\n'
            'esac\n')
        (bin_dir / 'curl').write_text(
            '#!/bin/bash\n'
            'printf "%s\\n" "$*" >> "$ARGV_LOG"\n'
            'config=$(cat)\n'
            'case "$config" in *"Bearer $EXPECTED_TOKEN"*) echo \'{"login": "emin"}\' ;; *) exit 22 ;; esac\n')
        for tool in ('security', 'curl'):
            os.chmod(bin_dir / tool, 0o755)
        argv_log, keychain = work / 'argv.log', work / 'keychain'
        env = dict(os.environ, PATH=f'{bin_dir}:{os.environ.get("PATH", "")}', USER='emin',
                   ARGV_LOG=str(argv_log), KEYCHAIN=str(keychain), EXPECTED_TOKEN=expected)
        result = subprocess.run(['bash', str(STORE_SCRIPT)], input=f'{self.TOKEN}\n{self.TOKEN}\n',
                                capture_output=True, text=True, env=env, timeout=30)
        return result, argv_log.read_text() if argv_log.exists() else '', keychain

    def test_store_script_keeps_the_token_out_of_argv(self):
        if not Path('/usr/bin/python3').exists():
            self.skipTest('the script parses the GitHub reply with /usr/bin/python3')
        result, argv, keychain = self.run_script(expected=self.TOKEN)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('Stored release token for emin', result.stdout)
        self.assertEqual(keychain.read_text(), self.TOKEN)
        self.assertIn('add-generic-password -a emin -s dot-github-token -U -w', argv)
        for text in (argv, result.stdout, result.stderr):
            self.assertNotIn(self.TOKEN, text)

    def test_a_token_github_refuses_is_removed_again(self):
        if not Path('/usr/bin/python3').exists():
            self.skipTest('the script parses the GitHub reply with /usr/bin/python3')
        result, argv, keychain = self.run_script(expected='ghp_SomeOtherToken')
        self.assertEqual(result.returncode, 1)
        self.assertFalse(keychain.exists())
        self.assertIn('delete-generic-password -a emin -s dot-github-token', argv)
        self.assertIn('GitHub did not accept the token', result.stderr)
        for text in (argv, result.stdout, result.stderr):
            self.assertNotIn(self.TOKEN, text)

    def test_script_and_owner_steps_prompt_instead_of_passing_the_token(self):
        self.assertEqual(subprocess.run(['bash', '-n', str(STORE_SCRIPT)]).returncode, 0)
        script = STORE_SCRIPT.read_text()
        self.assertIn('SERVICE="dot-github-token"', script)
        self.assertRegex(script, r'(?m)^security add-generic-password -a "\$USER" -s "\$SERVICE" -U -w$')
        steps = (ROOT / 'docs/QUESTIONS_FOR_EMIN.md').read_text().partition('## 1.')[2].partition('\n## 2.')[0]
        self.assertRegex(steps, r'(?m)^security add-generic-password -a "\$USER" -s dot-github-token -U -w$')
        for text in (script, steps):
            self.assertNotRegex(text, r'-w\s+"?\$')


if __name__ == '__main__':
    unittest.main()
