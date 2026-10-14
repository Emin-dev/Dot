"""Mutations of the portable guard; executable handoff tests remain authoritative."""
import ast
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
tree = ast.parse((ROOT / 'scripts/check_contracts.py').read_text())
function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'runtime_handoff_contract')
scope = {'ast': ast}
exec(compile(ast.Module(body=[function], type_ignores=[]), 'runtime-handoff-guard', 'exec'), scope)
check = scope['runtime_handoff_contract']


class RuntimeContractGuardTests(unittest.TestCase):
    def setUp(self):
        self.fixture = '''with _process.api_key_pipe(api_key) as key_fd:
    child = subprocess.Popen(command, pass_fds=(listener.fileno(), key_fd))
relay.close()
'''
    def test_actual_supervisor_passes(self):
        self.assertTrue(check((ROOT / 'Resources/Runtime/dot_runtime.py').read_text()))
    def test_scoped_pair_passes_in_either_order(self):
        self.assertTrue(check(self.fixture))
        self.assertTrue(check(self.fixture.replace('listener.fileno(), key_fd', 'key_fd, listener.fileno()')))
    def test_missing_extra_wrong_or_repeated_capability_fails(self):
        for replacement in ('listener.fileno(),', 'key_fd,', 'listener.fileno(), key_fd, unwanted',
                            'listener.fileno(), unrelated', 'key_fd, key_fd'):
            with self.subTest(replacement=replacement):
                self.assertFalse(check(self.fixture.replace('listener.fileno(), key_fd', replacement)))
    def test_spawn_must_be_inside_credential_pipe_scope(self):
        self.assertFalse(check(self.fixture.replace('    child =', '    pass\nchild =')))
        self.assertFalse(check(self.fixture.replace('_process.api_key_pipe(api_key)', 'unrelated()')))
        self.assertFalse(check(self.fixture.replace('_process.api_key_pipe(api_key)', '_process.api_key_pipe(other_key)')))
    def test_binding_and_cleanup_must_match(self):
        self.assertFalse(check(self.fixture.replace('as key_fd:', 'as other_fd:')))
        self.assertFalse(check(self.fixture.replace('relay.close()', '# relay.close()')))
    def test_comment_spoof_extra_spawn_and_invalid_syntax_fail(self):
        self.assertFalse(check('# ' + self.fixture.replace('\n', '\n# ')))
        self.assertFalse(check(self.fixture + 'other = subprocess.Popen(command)\n'))
        self.assertFalse(check(self.fixture + 'not valid python :\n'))


if __name__ == '__main__': unittest.main()
