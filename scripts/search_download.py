"""Build-only official artifact transport; downloaded bytes remain inert.

The build lock, mandatory digest and size verify content identity. HTTPS and the
redirect allowlist independently prevent downgrade or credential-bearing URLs.
This is not the application's user-controlled source-reading transport.
"""
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, build_opener

ORIGINS = frozenset({
    'files.pythonhosted.org', 'pypi.org', 'github.com', 'api.github.com',
    'codeload.github.com', 'www.python.org', 'astral-sh.github.io',
    'thrysoee.dk', 'www.sqlite.org', 'prdownloads.sourceforge.net',
})
REDIRECT_ORIGINS = ORIGINS | {
    'release-assets.githubusercontent.com', 'objects.githubusercontent.com',
    'downloads.sourceforge.net', 'sourceforge.net',
}

def validate_url(url, *, redirect=False):
    parsed = urlsplit(url)
    hosts = REDIRECT_ORIGINS if redirect else ORIGINS
    host = parsed.hostname or ''
    sourceforge_mirror = redirect and host.endswith('.dl.sourceforge.net')
    if (parsed.scheme != 'https' or (host not in hosts and not sourceforge_mirror)
            or parsed.username is not None or parsed.password is not None
            or parsed.port not in (None, 443) or parsed.fragment
            or any(ord(c) < 32 or ord(c) == 127 for c in url)):
        raise ValueError('unreviewed artifact origin or redirect')
    return url

class ArtifactRedirectHandler(HTTPRedirectHandler):
    max_repeats = 2
    max_redirections = 5

    def redirect_request(self, request, fp, code, message, headers, newurl):
        validate_url(newurl, redirect=True)
        return super().redirect_request(request, fp, code, message, headers, newurl)

def open_artifact(url, *, timeout=120):
    validate_url(url)
    # Explicit build transport does not inherit proxy credentials/settings.
    return build_opener(ProxyHandler({}), ArtifactRedirectHandler()).open(url, timeout=timeout)

def safe_target(path):
    path = Path(path).absolute()
    # The caller owns this build directory. Reject existing aliases rather than
    # follow them; an adversarial concurrent directory swap is outside this tool.
    for node in (path, *path.parents):
        if node.is_symlink():
            raise ValueError('symlink artifact target or parent')
    if path.exists() and not path.is_file():
        raise ValueError('artifact target is not a regular file')
    return path
