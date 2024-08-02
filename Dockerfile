ARG VERSION=1.16.0

FROM python:3.8-alpine3.20
LABEL maintainer="Jun Sun <jsun@junsun.net>"

ARG VERSION

COPY ./patch/* /tmp/

# leveldb v1.23 disables rtti and cause unfound relocation error
RUN chmod a+x /usr/local/bin/* && \
    apk add --no-cache git build-base openssl && \
    apk add --allow-untrusted /tmp/leveldb-1.22-r2.apk && \
    apk add --allow-untrusted /tmp/leveldb-dev-1.22-r2.apk && \
    pip install aiohttp ujson uvloop && \
    git clone -b $VERSION https://github.com/spesmilo/electrumx.git && \
    cd electrumx && \
    pip install . && \
    apk del git build-base && \
    rm -rf /tmp/*

VOLUME ["/data"]
WORKDIR /data

COPY ./bin /usr/local/bin

ENV HOME /data
ENV ALLOW_ROOT 1
ENV EVENT_LOOP_POLICY uvloop
ENV DB_DIRECTORY /data/electrumx-db
ENV SERVICES=tcp://:50001,ssl://:50002,rpc://0.0.0.0:8000
ENV SSL_CERTFILE ${HOME}/electrumx.crt
ENV SSL_KEYFILE ${HOME}/electrumx.key
ENV HOST ""

EXPOSE 50001 50002 8000

CMD ["init"]
