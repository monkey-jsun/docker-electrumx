#!/bin/sh
#
# Shut electrumx down cleanly.  Used as bin/init's SIGTERM handler, and by hand
# to force a clean restart -- under an "unless-stopped" policy the container
# comes straight back.  To stop it for good, use docker stop.

STOP_TIMEOUT=${STOP_TIMEOUT:-900}

if ! pkill -TERM -f electrumx_server; then
    echo "electrumx_server is not running"
    exit 0
fi

echo "SIGTERM sent, waiting up to ${STOP_TIMEOUT}s for a clean shutdown"
waited=0
while pkill -0 -f electrumx_server 2>/dev/null; do
    waited=$((waited + 1))
    if [ "$waited" -ge "$STOP_TIMEOUT" ]; then
        echo "still running after ${STOP_TIMEOUT}s -- not forcing, check the log"
        exit 1
    fi
    sleep 1
done

echo "electrumx stopped cleanly after ${waited}s"
