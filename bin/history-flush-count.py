#!/usr/bin/env python3

'''Print ElectrumX's current history flush count.

ElectrumX packs this counter into a big-endian uint16 (see
electrumx/server/history.py:flush()), so once it reaches 65,536 the server
dies on every flush with:

    struct.error: 'H' format requires 0 <= number <= 65535

The counter is only reset by electrumx_compact_history, which needs the
database to itself.  bin/init reads this value while the server is still
down so it can compact before the overflow rather than after.

Prints 0 -- "nothing to worry about" -- when the history DB has not been
created yet or cannot be read, so a fresh sync is never blocked by us.
'''

import ast
import os
import sys


def flush_count():
    hist_dir = os.path.join(os.getenv('DB_DIRECTORY', '.'), 'hist')
    if not os.path.isdir(hist_dir):
        return 0

    import plyvel
    # ElectrumX is not running when we are called, so an exclusive open is
    # safe; keep max_open_files low since we only read one key.
    db = plyvel.DB(hist_dir, create_if_missing=False, max_open_files=32)
    try:
        state = db.get(b'state\0\0')
    finally:
        db.close()

    if not state:
        return 0
    return ast.literal_eval(state.decode())['flush_count']


try:
    print(flush_count())
except Exception as e:
    print('could not read history flush count: %s' % e, file=sys.stderr)
    print(0)
