#!/bin/bash
#
# Run the server locally for debugging.
#
#   ./run-electrumx-alpine.sh       run the server (default CMD, i.e. bin/init)
#   ./run-electrumx-alpine.sh -i    drop into a shell in the same container
#
# Credentials are NOT kept here -- this repo is a fork of a public one.  They
# live in debug-env.sh one directory up, outside the repo; see
# debug-env.sh.example for the shape.  Override the location with DEBUG_ENV.
#
# Note we deliberately do NOT pass --user: bin/init starts mariadbd, which has
# to run as root in this image (see commit aad8462).

set -e

here=$(cd "$(dirname "$0")" && pwd)

DEBUG_ENV=${DEBUG_ENV:-$here/../debug-env.sh}
if [ ! -e "$DEBUG_ENV" ]; then
    echo "no credentials file at $DEBUG_ENV" >&2
    echo "copy $here/debug-env.sh.example there and fill it in" >&2
    exit 1
fi
. "$DEBUG_ENV"

: "${DAEMON_URL:?not set in $DEBUG_ENV}"
: "${EX_WRITER_PASS:?not set in $DEBUG_ENV}"
: "${EX_READER_PASS:?not set in $DEBUG_ENV}"

IMAGE=${IMAGE:-juliansun/js-electrumx:latest}

# what the outside world should connect to; bin/init works this out too, but
# setting it here keeps the container usable if it cannot reach ifconfig.me
PUBLIC_IP=$(curl -s http://whatismyip.akamai.com/)

if [ "$1" = "-i" ] || [ "$1" = "--interactive" ]; then
    shift
    command=(ash)
else
    command=()
fi

exec docker run \
    -it \
    --rm \
    -v "$here/data:/data" \
    -p 50001-50002:50001-50002 \
    -e DAEMON_URL="$DAEMON_URL" \
    -e COIN=Bitcoin \
    -e SERVICES=tcp://:50001,ssl://:50002,rpc://127.0.0.1:8000 \
    -e REPORT_SERVICES=ssl://$PUBLIC_IP:50002 \
    -e LOG_LEVEL=debug \
    -e EX_WRITER_PASS="$EX_WRITER_PASS" \
    -e EX_READER_PASS="$EX_READER_PASS" \
    "$@" \
    "$IMAGE" "${command[@]}"
