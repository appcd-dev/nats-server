# syntax=docker/dockerfile:1
# Hardened nats:2.15.3. The server binary is already v2.15.3.
# The Alpine image was blocked because every layer still contained zlib 1.3.2.
# This image is one layer: a scratch root with the static binary, certs, and
# the default config. There is no Alpine and no zlib.

FROM --platform=$BUILDPLATFORM golang:1.27.3-alpine3.24 AS build

ARG TARGETOS
ARG TARGETARCH

RUN apk add --no-cache ca-certificates tzdata \
    && update-ca-certificates

ENV CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH
# go install refuses GOBIN when cross-compiling, and then writes to
# $GOPATH/bin/$GOOS_$GOARCH. Copy whichever path it used.
RUN go install -trimpath github.com/nats-io/nats-server/v2@v2.15.3 \
    && src="$(go env GOPATH)/bin/${TARGETOS}_${TARGETARCH}/nats-server" \
    && if [ ! -x "$src" ]; then src="$(go env GOPATH)/bin/nats-server"; fi \
    && mkdir -p /tmp/bin \
    && cp "$src" /tmp/bin/nats-server \
    && go version -m /tmp/bin/nats-server | grep 'nats-server/v2' | grep -q 'v2.15.3' \
    && mkdir -p /out/usr/local/bin /out/etc/ssl/certs /out/etc/nats /out/usr/share \
    && cp /tmp/bin/nats-server /out/usr/local/bin/nats-server \
    && cp /etc/ssl/certs/ca-certificates.crt /out/etc/ssl/certs/ca-certificates.crt \
    && cp -a /usr/share/zoneinfo /out/usr/share/zoneinfo \
    && cat > /out/etc/nats/nats-server.conf <<'EOF'
# Same default as the official nats:2.15.3-alpine image.
port: 4222
monitor_port: 8222
cluster {
  name: "my_cluster"
  port: 6222
  authorization {
    user: ruser
    password: T0pS3cr3t
    timeout: 2
  }
  routes = []
}
EOF

FROM scratch

COPY --from=build /out/ /

ENV PATH="/usr/local/bin"

EXPOSE 4222 8222 6222

ENTRYPOINT ["nats-server"]
CMD ["--config", "/etc/nats/nats-server.conf"]

LABEL org.opencontainers.image.title="NATS Server" \
      org.opencontainers.image.source="https://github.com/nats-io/nats-server" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.version="2.15.3"
