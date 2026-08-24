#!/usr/bin/env python3

'''Look up transactions the way electrumx-tx-parser.py does, by hand.

    get-tx.py <txid> [<txid> ...]

Prints the decoded transaction and, more usefully, the exact row the parser
would have inserted into electrumx_transactions.transaction.  Uses the same
bitcoind_rpc module as the parser, so if this works the parser's lookup works
and any problem is downstream in the mysql half.

Needs DAEMON_URL set, same as ElectrumX itself:

    . ../debug-env.sh && bin/get-tx.py <txid>
'''

import pprint
import sys

import bitcoind_rpc


def show(tx_id):
    print('=' * 72)
    print(tx_id)
    try:
        obj = bitcoind_rpc.call('getrawtransaction', [tx_id, True],
                                caller='get-tx')
    except Exception as e:
        # bitcoind answers -5 for a tx it has neither in a block nor in the
        # mempool -- the same case the parser logs and skips
        print('  lookup failed: %s' % e)
        return 1

    pprint.pprint(obj)

    # mirror add_tx_record()'s arithmetic
    value = 0.0
    for a in obj['vout']:
        value += a['value']
    print()
    print('  parser would record:')
    print('    size=%d vsize=%d' % (obj['size'], obj['vsize']))
    print('    vin=%d vout=%d' % (len(obj['vin']), len(obj['vout'])))
    print('    value=%.8f' % value)
    print('    confirmed=%s' % ('no (still in mempool)'
                                if 'blockhash' not in obj else obj['blockhash']))
    return 0


if len(sys.argv) < 2:
    print(__doc__.strip(), file=sys.stderr)
    sys.exit(2)

sys.exit(max(show(t) for t in sys.argv[1:]))
