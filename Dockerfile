# syntax=docker/dockerfile:1
# Hardened nats:2.15.3.
#
# XRAY-1162975 does not apply. The binary is nats-server v2.15.3, and the
# fix shipped in v2.15.2.
#
# CVE-2026-4738: same base as nats:2.15.3-alpine (Alpine 3.22.8). zlib is
# upgraded from 1.3.2-r1 to 1.4-r0, then the filesystem is copied onto
# scratch. Xray scans that copy, so the old zlib layer is not in the image.
# The shell and the Alpine tools stay.

FROM --platform=$BUILDPLATFORM golang:1.27.3-alpine3.24 AS build

ARG TARGETOS
ARG TARGETARCH

ENV CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH
# go install refuses GOBIN when cross-compiling, and then writes to
# $GOPATH/bin/$GOOS_$GOARCH. Copy whichever path it used.
RUN go install -trimpath github.com/nats-io/nats-server/v2@v2.15.3 \
    && src="$(go env GOPATH)/bin/${TARGETOS}_${TARGETARCH}/nats-server" \
    && if [ ! -x "$src" ]; then src="$(go env GOPATH)/bin/nats-server"; fi \
    && mkdir -p /tmp/bin \
    && cp "$src" /tmp/bin/nats-server \
    && go version -m /tmp/bin/nats-server | grep 'nats-server/v2' | grep -q 'v2.15.3'

FROM alpine:3.22.8 AS rootfs

RUN set -eux; \
    apk -U upgrade; \
    apk add --no-cache ca-certificates tzdata; \
    apk add --no-cache --upgrade 'zlib=1.4-r0'; \
    zlib_ver="$(apk list -I zlib)"; \
    echo "${zlib_ver}"; \
    echo "${zlib_ver}" | grep -q '^zlib-1.4-r0 '; \
    echo "${zlib_ver}" | grep -q '1.3' && exit 1 || true; \
    rm -rf /var/cache/apk; \
    mkdir -p /var/cache/apk /etc/nats

COPY --from=build /tmp/bin/nats-server /usr/local/bin/nats-server

RUN cat > /usr/local/bin/docker-entrypoint.sh <<'EOF'
#!/bin/sh
set -e

# this if will check if the first argument is a flag
# but only works if all arguments require a hyphenated flag
# -v; -SL; -f arg; etc will work, but not arg1 arg2
if [ "$#" -eq 0 ] || [ "${1#-}" != "$1" ]; then
    set -- nats-server "$@"
fi

# else default to run whatever the user wanted like "bash" or "sh"
exec "$@"
EOF

RUN cat > /etc/nats/nats-server.conf <<'EOF'
# Client port of 4222 on all interfaces
port: 4222

# HTTP monitoring port
monitor_port: 8222

# This is for clustering multiple servers together.
cluster {
  # It is recommended to set a cluster name
  name: "my_cluster"

  # Route connections to be received on any interface on port 6222
  port: 6222

  # Routes are protected, so need to use them with --routes flag
  # e.g. --routes=nats-route://ruser:T0pS3cr3t@otherdockerhost:6222
  authorization {
    user: ruser
    password: T0pS3cr3t
    timeout: 2
  }

  # Routes are actively solicited and connected to from this server.
  # This Docker image has none by default, but you can pass a
  # flag to the nats-server docker image to create one to an existing server.
  routes = []
}
EOF

RUN chmod 755 /usr/local/bin/nats-server /usr/local/bin/docker-entrypoint.sh

FROM scratch

COPY --from=rootfs / /

ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    NATS_SERVER=2.15.3

EXPOSE 4222 8222 6222

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["nats-server", "--config", "/etc/nats/nats-server.conf"]

LABEL org.opencontainers.image.title="NATS Server" \
      org.opencontainers.image.source="https://github.com/nats-io/nats-server" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.version="2.15.3"
