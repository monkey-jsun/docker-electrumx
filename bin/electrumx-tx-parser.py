#!/usr/bin/env python3

import re
import subprocess
import sys
import time
import os
import threading
from datetime import datetime
import mysql.connector
import bitcoind_rpc

# set TEST=1 to do testing with polluting production system
#   output printed on console instead of log file
#   mysql transactions are not commited

# redirect stdio/stderr to a file
#if os.getenv("TEST") == None:
#    output_file=open("/data/tx-parser.log", "a")
#    if not output_file:
#        print("failed to open file for write")
#        exit(1)
#    sys.stdout=output_file
#    sys.stderr=output_file

# declare program starting
local_time=datetime.now().strftime('%Y-%m-%d %H:%M:%S')
print("%s - ex-parser starting ... \n" % (local_time))

# how long to wait before asking bitcoind about a freshly broadcast tx,
# and how hard to retry.  The tx is already in our own mempool by the time
# the log line is emitted, so this only needs to absorb a brief race.
TX_LOOKUP_DELAY = 2
TX_LOOKUP_ATTEMPTS = 3
TX_LOOKUP_RETRY_WAIT = 5

# one mysql connection shared by every worker thread, so serialise the
# cursor/commit pairs -- two threads interleaving on one connection corrupts
# the protocol state
db_lock = threading.Lock()

# ElectrumX packs its history flush counter into a uint16 and dies on every
# flush once it passes 65,535.  Only electrumx_compact_history resets it, and
# that needs the server stopped -- so when the counter reaches the threshold we
# stop it ourselves, cleanly.  bin/init compacts on the way back up and the
# container returns under docker's restart policy (portainer: "always unless
# stopped").
#
# db.py logs the counter on every flush and we already read every line it
# writes, so we trigger on the real condition rather than on a timer: this
# fires only when a compaction is actually due, roughly once every two years.
#
# This is the same COMPACT_AT_FLUSH_COUNT that bin/init gates compaction on --
# deliberately one number, so a restart always lands on a boot that compacts.
# Env-tunable so a dev box can rehearse the whole cycle with a small value.
# Set it to 0 to disable the restart.
COMPACT_AT_FLUSH_COUNT = int(os.getenv('COMPACT_AT_FLUSH_COUNT', '60000'))

# A clean shutdown can take a while -- it finishes the flush in progress and
# closes several large leveldbs.  Wait, but not forever: if SIGTERM has not
# taken effect by now something is wedged, and hanging here would leave the
# counter at the ceiling with no restart coming.  A SIGKILL costs us a
# clear_excess scan on the next start, which is slow but safe and happens
# before the compaction anyway.
SHUTDOWN_GRACE = int(os.getenv('SHUTDOWN_GRACE_SECS', '900'))

# matches both "flush #65,535 took ..." and "backup flush #65,535 took ..."
flush_count_re = re.compile(r'flush #([\d,]+)')
restart_requested = False


def _signal_electrumx(sig):
    # SIGTERM first: server_base.py turns it into a clean shutdown.  The
    # pattern cannot match this parser -- our argv says electrumx-tx-parser.py,
    # not electrumx_server.
    return subprocess.call(['pkill', sig, '-f', 'electrumx_server'])


def _escalate_if_still_running():
    time.sleep(SHUTDOWN_GRACE)
    # pkill returns 0 only if it matched something still alive
    if _signal_electrumx('-0') == 0:
        print("ex-parser - electrumx still running %ds after SIGTERM; "
              "sending SIGKILL" % SHUTDOWN_GRACE)
        sys.stdout.flush()
        _signal_electrumx('-KILL')


def maybe_request_restart(line):
    '''Stop ElectrumX cleanly once its flush counter reaches the threshold.'''
    global restart_requested
    if restart_requested or COMPACT_AT_FLUSH_COUNT <= 0:
        return
    m = flush_count_re.search(line)
    if not m:
        return
    count = int(m.group(1).replace(',', ''))
    if count <= COMPACT_AT_FLUSH_COUNT:
        return

    restart_requested = True
    print("ex-parser - history flush count %d passed the threshold %d"
          % (count, COMPACT_AT_FLUSH_COUNT))
    print("ex-parser - stopping electrumx so bin/init can compact the history "
          "DB on the way back up")
    sys.stdout.flush()
    try:
        _signal_electrumx('-TERM')
        threading.Thread(target=_escalate_if_still_running, daemon=True).start()
    except Exception as e:
        # never let this kill the parser: our stdout is electrumx's stdout, so
        # dying here would break the pipe and take the server down messily
        print("ex-parser - could not signal electrumx: %s" % e)
        sys.stdout.flush()

# Resolve DAEMON_URL now rather than on the first broadcast, so a bad or
# missing one is a loud startup failure instead of a surprise hours later.
bitcoind_rpc.daemon_endpoint()

# === helpers ===
def init_db():
    # connect to mysql db
    return mysql.connector.connect(
        host="localhost",
        user="ex_writer",
        password=os.getenv('EX_WRITER_PASS'),
        unix_socket='/run/mysqld/mysqld.sock',
        database="electrumx_transactions")

def get_cursor():
    global mydb
    try:
        print("ex-parser - ping db ...")
        mydb.ping(reconnect=True, attempts=3, delay=5)
    except mysql.connector.Error as err:
        print("ex-parser - re-connect to db ...")
        mydb = init_db()
    return mydb.cursor()

def get_tx_details(tx_id):
    # Ask our own node.  The tx was just broadcast through us so it is in our
    # mempool; getrawtransaction serves mempool txs even without txindex, and
    # the verbose form returns the same shape we used to get from blockchair.
    for attempt in range(TX_LOOKUP_ATTEMPTS):
        try:
            return bitcoind_rpc.call('getrawtransaction', [tx_id, True])
        except Exception as e:
            print("ex-parser - getrawtransaction failed (%d/%d) for %s : %s"
                  % (attempt + 1, TX_LOOKUP_ATTEMPTS, tx_id, e))
            sys.stdout.flush()
            if attempt + 1 < TX_LOOKUP_ATTEMPTS:
                time.sleep(TX_LOOKUP_RETRY_WAIT)
    return None

def add_tx_record(tx_id, ip_addr, ip_port, received_time):
    # meant to run on a separate thread to avoid blocking main thread
    # we query our own bitcoind, so no need to wait for a third party to
    # notice the tx -- a short pause plus retries is enough
    time.sleep(TX_LOOKUP_DELAY)

    # get transaction details
    obj=get_tx_details(tx_id)
    if not obj:
        print("ex_parser - error transaction : %s" % (tx_id))
        sys.stdout.flush()
        return

    # extract from transacton detail
    vin_count = len(obj["vin"])
    vout_count = len(obj["vout"])

    # count total bitcoins
    value=0.0
    for a in obj["vout"]:
        value += a["value"]
    print("ex_parser - vin=%d, vout=%d, value=%f" % (vin_count, vout_count, value))

    # get size and vsize
    size=obj["size"]
    vsize=obj["vsize"]
    print("ex_parser - size=%d, vsize=%d" % (size, vsize))

    # insert into mysql
    val = (received_time, tx_id, size, vsize, vin_count, vout_count, value, ip_addr, ip_port)
    with db_lock:
        mycursor = get_cursor()
        mycursor.execute(sql, val)
        mydb.commit()
        rowcount = mycursor.rowcount
        mycursor.close()
    print("ex_parser - %d record is inserted" % (rowcount))

    #flush
    sys.stdout.flush()

# === the main part ===

mydb = init_db()

sql = "INSERT INTO transaction (received_time, tx_id, size, vsize, vin_count, vout_count, value, ip_addr, port) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)" 


for line in sys.stdin:
    # emulate 'tee' feature
    print(line,end="")
    sys.stdout.flush()

    line=line.strip()

    # watch electrumx's own flush logging for the uint16 ceiling
    maybe_request_restart(line)

    if not re.search("sent tx from",line):
        continue

    # we found a tx line!!
    local_time=datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    print("---------------")
    print(local_time)
    print("ex-parser - found tx : ", line)

    # get variables from log line
    _,_,_,_,ip_addr,_,tx_id,*not_used=line.split()
    ip_addr,ip_port=ip_addr.split(":")
    print("ex-parser - ip=%s:%s" % (ip_addr, ip_port))

    # remove last char if it is ".".  This can happen some times
    if tx_id[-1] == '.':
        tx_id=tx_id[:-1]
    print("ex-parser - tx_id=%s" % (tx_id))

    # start a thread to deal with adding record.  local_time is passed by
    # value: the main loop reassigns it on the next broadcast, which would
    # otherwise be read by this thread after it wakes and misattribute the
    # received_time to a later tx.
    x = threading.Thread(target=add_tx_record,
                         args=(tx_id,ip_addr,ip_port,local_time))
    x.start()

    #flush
    sys.stdout.flush()

# exit - we don't get here??
sys.exit(0)
