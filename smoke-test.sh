#!/bin/bash
#
# Smoke test for the built image.  Read-only: it never starts the server, never
# runs a real compaction, and never touches data/electrumx-db -- every history
# DB it looks at is a synthetic fixture built fresh under a temp directory.
#
#   ./smoke-test.sh
#
# Credentials come from ../debug-env.sh (see debug-env.sh.example).  Check 8
# needs a reachable bitcoind and is skipped if there isn't one.

set -u

here=$(cd "$(dirname "$0")" && pwd)
IMAGE=${IMAGE:-juliansun/js-electrumx:latest}
DEBUG_ENV=${DEBUG_ENV:-$here/../debug-env.sh}
[ -e "$DEBUG_ENV" ] && . "$DEBUG_ENV"
DAEMON_URL=${DAEMON_URL:-}

pass=0; fail=0; skip=0
ok()   { echo "  PASS  $1"; pass=$((pass+1)); }
no()   { echo "  FAIL  $1"; echo "        expected: $2"; echo "        actual:   $3"; fail=$((fail+1)); }
skipd(){ echo "  SKIP  $1 ($2)"; skip=$((skip+1)); }
check(){ # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "$2" "$3"; fi
}

work=$(mktemp -d)
# the fixtures get created by root inside the container, so clear them out the
# same way before removing the directory from here
cleanup() {
    docker run --rm -v "$work:/work" --entrypoint sh "$IMAGE" \
        -c 'rm -rf /work/full /work/low /work/nostate /work/stub' >/dev/null 2>&1
    rm -rf "$work"
}
trap cleanup EXIT

# A stub standing in for the real electrumx_compact_history: it proves the gate
# fired, and drops the counter the way a real compaction would, so the line
# bin/init prints afterwards has something real to report.
cat > "$work/fake-compact" <<'STUB'
#!/usr/bin/env python3
import ast, os, plyvel, sys
print('STUB COMPACTION RAN')
d = os.path.join(os.environ['DB_DIRECTORY'], 'hist')
db = plyvel.DB(d)
st = ast.literal_eval(db.get(b'state\0\0').decode())
st['flush_count'] = 1
db.put(b'state\0\0', repr(st).encode())
db.close()
STUB
chmod 755 "$work/fake-compact"

# Build the fixtures, then run every in-image check in one container.
cat > "$work/fixtures.py" <<'PYEOF'
import os, plyvel
def mk(name, state):
    d = os.path.join('/work', name, 'hist')
    os.makedirs(os.path.dirname(d), exist_ok=True)
    db = plyvel.DB(d, create_if_missing=True)
    if state is not None:
        db.put(b'state\0\0', repr(state).encode())
    db.close()
# the exact state the crash log reported
mk('full', {'flush_count': 65535, 'comp_flush_count': -1, 'comp_cursor': -1,
            'db_version': 1, 'upgrade_cursor': -1})
mk('low',  {'flush_count': 137, 'db_version': 1})
mk('nostate', None)
PYEOF

echo "image: $IMAGE"
echo

# ---------------------------------------------------------------- checks 1-4
echo "history flush counter"
out=$(docker run --rm -v "$work:/work" --entrypoint sh "$IMAGE" -c '
python3 /work/fixtures.py
DB_DIRECTORY=/work/full     history-flush-count.py
DB_DIRECTORY=/work/low      history-flush-count.py
DB_DIRECTORY=/work/nostate  history-flush-count.py
DB_DIRECTORY=/work/missing  history-flush-count.py
' 2>/dev/null)
check "1. crashed DB reports 65535"     "65535" "$(echo "$out" | sed -n 1p)"
check "2. healthy DB reports 137"       "137"   "$(echo "$out" | sed -n 2p)"
check "3. DB with no state reports 0"   "0"     "$(echo "$out" | sed -n 3p)"
check "4. absent DB reports 0"          "0"     "$(echo "$out" | sed -n 4p)"

# ---------------------------------------------------------------- checks 5-6
# Run the real lines out of bin/init, with the compaction command replaced.
sed -n '/^COMPACT_AT_FLUSH_COUNT=/,/^fi$/p' "$here/bin/init" > "$work/gate.sh"
if ! grep -q electrumx_compact_history "$work/gate.sh"; then
    no "gate extraction" "the compaction block from bin/init" "no match -- did bin/init change?"
else
    echo
    echo "bin/init compaction gate (bin/init default threshold, compaction stubbed)"
    gate() { docker run --rm -v "$work:/work" \
        -v "$work/fake-compact:/electrumx/electrumx_compact_history:ro" \
        -e DB_DIRECTORY="/work/$1" --entrypoint sh "$IMAGE" /work/gate.sh 2>&1; }

    # fixtures live in the container only for the life of a run; rebuild them
    docker run --rm -v "$work:/work" --entrypoint python3 "$IMAGE" /work/fixtures.py >/dev/null 2>&1

    g=$(gate full)
    if echo "$g" | grep -q 'STUB COMPACTION RAN' && echo "$g" | grep -q 'is now 1'; then
        ok "5. at 65535 it compacts, and sees the counter reset"
    else
        no "5. at 65535 it compacts" "STUB COMPACTION RAN + 'is now 1'" "$(echo "$g" | tr '\n' '|')"
    fi

    g=$(gate low)
    if echo "$g" | grep -q 'STUB COMPACTION RAN'; then
        no "6. at 137 it skips" "no compaction" "$(echo "$g" | tr '\n' '|')"
    else
        ok "6. at 137 it skips compaction"
    fi
fi

# --------------------------------------------------------------- checks 7-10
echo
echo "image wiring"
out=$(docker run --rm --entrypoint sh "$IMAGE" -c '
python3 -c "import sys; sys.path.insert(0,\"/usr/local/bin\"); import bitcoind_rpc; print(\"import-ok\")"
command -v electrumx_compact_history >/dev/null && echo compact-on-path
sh -n /usr/local/bin/init && echo init-parses
' 2>&1)
[ "$(echo "$out" | grep -c import-ok)" = "1" ] && ok "7.  bitcoind_rpc imports in image" || no "7.  bitcoind_rpc imports in image" "import-ok" "$out"
[ "$(echo "$out" | grep -c compact-on-path)" = "1" ] && ok "10a. electrumx_compact_history on PATH" || no "10a. electrumx_compact_history on PATH" "found" "$out"
[ "$(echo "$out" | grep -c init-parses)" = "1" ] && ok "10b. bin/init parses" || no "10b. bin/init parses" "clean sh -n" "$out"

# 9. parser must fail fast and loudly on a bad DAEMON_URL, before mysql
out=$(docker run --rm -e DAEMON_URL= --entrypoint sh "$IMAGE" -c \
    'echo | electrumx-tx-parser.py' 2>&1)
if echo "$out" | grep -q 'DAEMON_URL is not set'; then
    ok "9.  empty DAEMON_URL fails fast with a clear message"
else
    no "9.  empty DAEMON_URL fails fast" "RuntimeError: DAEMON_URL is not set" "$(echo "$out" | tail -3 | tr '\n' '|')"
fi

# 8. real node, real transaction -- the assumption patch 0001 rests on
echo
echo "against the real node"
if [ -z "$DAEMON_URL" ]; then
    skipd "8.  real mempool tx decodes" "no DAEMON_URL"
else
    out=$(docker run --rm -e DAEMON_URL="$DAEMON_URL" --entrypoint sh "$IMAGE" -c '
python3 - <<'"'"'EOF'"'"'
import sys
sys.path.insert(0, "/usr/local/bin")
import bitcoind_rpc as rpc
mp = rpc.call("getrawmempool", [], caller="smoke")
if not mp:
    print("EMPTY-MEMPOOL"); sys.exit(0)
o = rpc.call("getrawtransaction", [mp[0], True], caller="smoke")
missing = [k for k in ("size","vsize","vin","vout") if k not in o]
sum(a["value"] for a in o["vout"])
print("MISSING:" + ",".join(missing) if missing else "ALL-FIELDS-PRESENT")
EOF' 2>&1 | tail -1)
    case "$out" in
        ALL-FIELDS-PRESENT) ok "8.  real mempool tx exposes every field the parser reads" ;;
        EMPTY-MEMPOOL)      skipd "8.  real mempool tx decodes" "mempool empty" ;;
        *)                  no "8.  real mempool tx decodes" "ALL-FIELDS-PRESENT" "$out" ;;
    esac
fi

# --------------------------------------------------------------- checks 11-13
# The restart trigger.  This runs entirely inside a container: pkill matches on
# command line, and container processes are visible from the host, so running
# it out here could signal a real electrumx_server you have running.
echo
echo "flush-count restart trigger"
mkdir -p "$work/stub/mysql"
: > "$work/stub/mysql/__init__.py"
cat > "$work/stub/mysql/connector.py" <<'EOF'
class Error(Exception): pass
class _C:
    def cursor(self): return self
    def ping(self, **k): pass
    def commit(self): pass
    def execute(self, *a): pass
    def close(self): pass
    rowcount = 0
def connect(**kw): return _C()
EOF

trig=$(docker run --rm -v "$work/stub:/stub" --entrypoint sh "$IMAGE" -c '
# a stand-in for the real server: pkill matches on command line
cp /bin/sleep /tmp/electrumx_server
/tmp/electrumx_server 300 &
dummy=$!
printf "INFO:DB:flush #50 took 1.0s.  Height 1 txs: 1 (+1)\n\
INFO:DB:backup flush #150 took 1.0s.  Height 1 txs: 1 (+1)\n" \
  | COMPACT_AT_FLUSH_COUNT=100 SHUTDOWN_GRACE_SECS=3 \
    DAEMON_URL=http://u:p@127.0.0.1:1/ PYTHONPATH=/stub \
    python3 /usr/local/bin/electrumx-tx-parser.py > /tmp/out 2>&1
echo "parser-exit=$?"
grep -q "flush count 150 passed the threshold 100" /tmp/out && echo TRIGGERED || echo NOT-TRIGGERED
grep -q "flush count 50 passed"  /tmp/out && echo EARLY-TRIGGER || echo NO-EARLY-TRIGGER
kill -0 $dummy 2>/dev/null && echo DUMMY-ALIVE || echo DUMMY-SIGNALLED
' 2>&1)

case "$trig" in
    *"NO-EARLY-TRIGGER"*) ok "11. flush count below threshold does not trigger" ;;
    *)                    no "11. flush count below threshold does not trigger" "NO-EARLY-TRIGGER" "$trig" ;;
esac
if echo "$trig" | grep -q '^TRIGGERED$'; then
    ok "12. 'backup flush #150' over threshold triggers the stop"
else
    no "12. over-threshold flush triggers the stop" "TRIGGERED" "$trig"
fi
if echo "$trig" | grep -q 'DUMMY-SIGNALLED'; then
    ok "13. it actually signals electrumx_server (parser survived: $(echo "$trig" | grep -o 'parser-exit=[0-9]*'))"
else
    no "13. it signals electrumx_server" "DUMMY-SIGNALLED" "$trig"
fi

# --------------------------------------------------------------- checks 14-17
# Database creation from the environment, against a real mariadb on a throwaway
# datadir.  Runs the block straight out of bin/init rather than a copy.
echo
echo "tx database created from EX_*_PASS"
sed -n '/# Create the tx db from the same/,/^    echo "tx database created/p' \
    "$here/bin/init" > "$work/dbinit.sh"
if ! grep -q 'ex_writer' "$work/dbinit.sh"; then
    no "db-init extraction" "the db creation block from bin/init" "no match -- did bin/init change?"
else
    # a password with a quote, a backslash and a space, to exercise sql_quote
    NASTY="p'a\\ss w0rd"
    db=$(docker run --rm -v "$work:/work" \
            -e EX_WRITER_PASS="$NASTY" -e EX_READER_PASS=readerpw \
            -e EX_ADMIN_PASS=adminpw --entrypoint sh "$IMAGE" -c '
mariadb-install-db --datadir=/tmp/db >/dev/null 2>&1
mariadbd-safe --datadir=/tmp/db --user=root >/dev/null 2>&1 &
for i in $(seq 30); do mariadb -u root -e "select 1" >/dev/null 2>&1 && break; sleep 1; done
# -x on purpose: the block must turn tracing off itself
sh -x /work/dbinit.sh 2>&1 | sed "s/^/TRACE:/"
mariadb -u ex_writer -p"$EX_WRITER_PASS" electrumx_transactions \
    -e "insert into transaction (received_time,tx_id,size,vsize,vin_count,vout_count,value,ip_addr,port) values (now(),\"ab\",1,1,1,1,0.5,\"1.2.3.4\",1)" \
    >/dev/null 2>&1 && echo WRITER-OK || echo WRITER-FAILED
mariadb -u ex_reader -preaderpw electrumx_transactions -e "select count(*) from transaction" >/dev/null 2>&1 \
    && echo READER-OK || echo READER-FAILED
mariadb -u ex_reader -preaderpw electrumx_transactions -e "delete from transaction" >/dev/null 2>&1 \
    && echo READER-CAN-DELETE || echo READER-READONLY
' 2>&1)

    echo "$db" | grep -q 'WRITER-OK'      && ok "14. ex_writer can insert (password with quote/backslash survived)" \
                                          || no "14. ex_writer can insert" "WRITER-OK" "$(echo "$db" | grep -v TRACE: | tr '\n' '|')"
    echo "$db" | grep -q 'READER-OK'      && ok "15. ex_reader can select" \
                                          || no "15. ex_reader can select" "READER-OK" "$(echo "$db" | grep -v TRACE: | tr '\n' '|')"
    echo "$db" | grep -q 'READER-READONLY' && ok "16. ex_reader cannot delete" \
                                          || no "16. ex_reader cannot delete" "READER-READONLY" "$(echo "$db" | grep -v TRACE: | tr '\n' '|')"
    # the whole point of the set +x: passwords must not reach the log
    if echo "$db" | grep -q "p'a"; then
        no "17. passwords stay out of the traced log" "no password in output" "leaked"
    else
        ok "17. passwords stay out of the traced log"
    fi
fi

echo
echo "----------------------------------------"
echo "passed $pass, failed $fail, skipped $skip"
[ "$fail" -eq 0 ] || exit 1
