#!/usr/bin/env python3

import urllib.request
import json
import pprint
import re
import sys
import time
import os
import threading
from datetime import datetime
import mysql.connector

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
    # print(tx_id)
    url="https://api.blockchair.com/bitcoin/raw/transaction/" + tx_id
    data=urllib.request.urlopen(url)
    obj=json.load(data)
    
    # check status and results
    if obj['context']['code'] != 200:
        print("ex-parser - URL open failed")
        return None
    elif obj['context']['results'] == 0:  
        print("ex-parser - portal cannot find TX : " + tx_id)
        return None
    else:
        return obj['data'][tx_id]['decoded_raw_transaction']

def add_tx_record(tx_id, ip_addr, ip_port):
    # meant to run on a separate thread to avoid blocking main thread
    # it will take a while for the tx to populate to the blockchair website
    # we wait for 5 minutes which might be extreme, but we avoid retrying
    time.sleep(60*5)

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
    val = (local_time, tx_id, size, vsize, vin_count, vout_count, value, ip_addr, ip_port)
    mycursor.execute(sql, val)
    mydb.commit()
    print("ex_parser - %d record is inserted" % (mycursor.rowcount))

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

    # re-get cursor because it might be a long while before we get a new input line
    mycursor = get_cursor()

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

    # start a thread to deal with adding record
    x = threading.Thread(target=add_tx_record, args=(tx_id,ip_addr,ip_port))
    x.start()

    #flush
    sys.stdout.flush()

# exit - we don't get here??
sys.exit(0)
