#!/usr/bin/env python3

'''Minimal JSON-RPC client for the bitcoind we are already fronting.

Shared by electrumx-tx-parser.py (which records broadcast transactions) and
get-tx.py (which is how you poke at that same lookup by hand).  Keeping one
copy means the debug tool cannot drift away from what production does.

Both importers are run as scripts out of /usr/local/bin, so sys.path[0] is
that directory and a plain "import bitcoind_rpc" finds this file.
'''

import base64
import json
import os
import urllib.error
import urllib.parse
import urllib.request


def daemon_endpoint():
    # Reuse ElectrumX's own DAEMON_URL rather than a second config knob.
    # Accepts 'http://user:pass@host:port/' or bare 'user:pass@host:port',
    # and takes the first entry if several are listed comma-separated.
    raw = os.getenv('DAEMON_URL', '').split(',')[0].strip().rstrip('/')
    if not raw:
        raise RuntimeError('DAEMON_URL is not set')
    if '://' not in raw:
        raw = 'http://' + raw
    parts = urllib.parse.urlsplit(raw)
    if not parts.username:
        raise RuntimeError('DAEMON_URL carries no credentials')
    userpass = '%s:%s' % (parts.username, parts.password or '')
    auth = base64.b64encode(userpass.encode()).decode()
    url = '%s://%s:%d/' % (parts.scheme, parts.hostname, parts.port or 8332)
    return url, 'Basic ' + auth


_endpoint = None


def call(method, params, caller='ex-parser'):
    global _endpoint
    if _endpoint is None:
        _endpoint = daemon_endpoint()
    url, auth = _endpoint
    payload = json.dumps({'jsonrpc': '1.0', 'id': caller,
                          'method': method, 'params': params}).encode()
    req = urllib.request.Request(
        url, data=payload,
        headers={'Content-Type': 'application/json',
                 'Authorization': auth})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            obj = json.load(resp)
    except urllib.error.HTTPError as e:
        # bitcoind reports RPC-level errors as HTTP 500 with the reason in the
        # body, so read it -- otherwise every failure logs as "HTTP Error 500"
        # and says nothing about what actually went wrong.
        try:
            err = json.load(e).get('error') or {}
        except Exception:
            raise e
        raise RuntimeError('%s (code %s)' % (err.get('message', err),
                                             err.get('code'))) from None
    if obj.get('error'):
        raise RuntimeError(obj['error'])
    return obj['result']
