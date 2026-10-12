#!/bin/bash
# Read-only direct Splash readiness test. No downloads, launches, or model calls.
set -euo pipefail
: "${DOT_SPLASH_URL:?Set a direct loopback Splash URL}"
: "${DOT_SPLASH_MODEL:?Set the exact expected Splash instance.model}"
python3 - <<'PY'
import json, os, urllib.parse, urllib.request
url=os.environ['DOT_SPLASH_URL']; parts=urllib.parse.urlsplit(url)
assert parts.scheme=='http' and parts.hostname in ('127.0.0.1','localhost','::1')
assert parts.port and not parts.username and not parts.password and not parts.query and not parts.fragment and parts.path in ('','/')
class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs): return None
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
with opener.open(url.rstrip('/')+'/status', timeout=4) as response:
    assert response.headers.get('Server')=='Splash'
    data=json.load(response)
assert data['schema_version']==6 and data['ready'] is True
assert data['instance']['model']==os.environ['DOT_SPLASH_MODEL']
assert data['instance']['port']==parts.port
print('PASS: direct Splash identity/readiness fixture; generation not exercised')
PY
