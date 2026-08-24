#!/usr/bin/env python3

import re
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
