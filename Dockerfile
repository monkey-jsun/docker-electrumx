ARG VERSION=1.16.0

FROM python:3.8-alpine3.20
LABEL maintainer="Jun Sun <jsun@junsun.net>"

ARG VERSION

COPY ./patch/* /tmp/

# leveldb v1.23 disables rtti and cause unfound relocation error
RUN chmod a+x /usr/local/bin/* && \
    apk add --no-cache git build-base openssl && \
    apk add --no-cache mysql mysql-client && \
    apk add --allow-untrusted /tmp/leveldb-1.22-r2.apk && \
    apk add --allow-untrusted /tmp/leveldb-dev-1.22-r2.apk && \
    pip install aiohttp ujson uvloop mysql-connector-python && \
    git clone --depth=1 -b $VERSION https://github.com/spesmilo/electrumx.git && \
    cd electrumx && \
    patch -p 1 < /tmp/tx_ip_addr.patch && \
    pip install . && \
    apk del git build-base && \
    rm -rf /tmp/*

RUN mkdir /run/mysqld && \
    chmod a+wx /run/mysqld 

#    git clone --depth=1 -b $VERSION https://github.com/spesmilo/electrumx.git && \
#    git checkout bf430353d635eeaf1d4fc0f107d6b947846e1d7f && \
#    echo "net.ipv6.conf.all.disable_ipv6=1" >> /etc/sysctl.conf && \

VOLUME ["/data"]
WORKDIR /data

COPY ./bin /usr/local/bin

ENV MARIADB=/data/mariadb

ENV HOME /data
ENV ALLOW_ROOT 1
ENV EVENT_LOOP_POLICY uvloop
ENV DB_DIRECTORY /data/electrumx-db
ENV SERVICES=tcp://:50001,ssl://:50002,rpc://127.0.0.1:8000
ENV SESSION_TIMEOUT=300
ENV SSL_CERTFILE ${HOME}/electrumx.crt
ENV SSL_KEYFILE ${HOME}/electrumx.key
ENV HOST ""

EXPOSE 50001 50002 8000

CMD ["init"]
