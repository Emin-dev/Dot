"""Verify generated nested preview script pins; browser enforcement is separate."""
from html.parser import HTMLParser
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[2]
PINS = {
    'https://unpkg.com/lucide@1.17.0/dist/umd/lucide.js': 'sha256-/eh4pPeuvlSLBx6q80PYmPZtJ16Tlwq+ldjKX9opC1E=',
    'https://unpkg.com/@floating-ui/core@1.7.3/dist/floating-ui.core.umd.min.js': 'sha256-aYXOZhFTwB2X9r6bq7apVm+SPHFsK3++rUj7sJ9Bm6g=',
    'https://unpkg.com/@floating-ui/dom@1.7.4/dist/floating-ui.dom.umd.min.js': 'sha256-uBmfdq3MubF7OrVxJMQlhdwZGXEn0aXRkwfRmD+AvYk=',
}
class Scripts(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.external = []
    def handle_starttag(self, tag, attributes):
        attributes = dict(attributes)
        if tag == 'script' and attributes.get('src'):
            self.external.append(attributes)
        if tag == 'iframe':
            document = attributes.get('srcdoc') or attributes.get('data-srcdoc')
            if document:
                nested = Scripts(); nested.feed(document); self.external.extend(nested.external)

def validate(text):
    parser = Scripts(); parser.feed(text)
    if len(parser.external) != len(PINS):
        raise ValueError('unexpected external script inventory')
    seen = set()
    for script in parser.external:
        src = script['src']
        if src in seen or src not in PINS or script.get('integrity') != PINS[src] or script.get('crossorigin') != 'anonymous':
            raise ValueError('unverified external script')
        seen.add(src)
    return seen

class PreviewIntegrityTests(unittest.TestCase):
    def previews(self):
        for name in ('dot-face-motion-directions.html', 'dot-ui-options.html'):
            yield name, (ROOT / 'docs/design' / name).read_text()
    def test_all_nested_external_scripts_have_exact_integrity_and_cors(self):
        for name, text in self.previews():
            with self.subTest(preview=name): self.assertEqual(validate(text), set(PINS))
    def test_missing_or_modified_integrity_cannot_pass_guard(self):
        for name, text in self.previews():
            for digest in PINS.values():
                with self.subTest(preview=name, pin=digest), self.assertRaises(ValueError):
                    validate(text.replace(digest, 'sha256-' + 'A' * 43 + '='))
    def test_changed_url_or_cors_cannot_pass_guard(self):
        for name, text in self.previews():
            for original, altered in [('https://unpkg.com/', 'https://example.invalid/'), ('anonymous', 'use-credentials')]:
                with self.subTest(preview=name, mutation=altered), self.assertRaises(ValueError):
                    validate(text.replace(original, altered))
