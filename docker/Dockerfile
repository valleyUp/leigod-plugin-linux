FROM debian:bookworm-slim

ARG LEIGOD_VERSION=1.2.2.15

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        iproute2 \
        ipset \
        iptables \
        procps \
    && rm -rf /var/lib/apt/lists/*

COPY opt/leigod/acc-gw.router.amd64 /opt/leigod/acc-gw.router.amd64
COPY opt/leigod/config/ /usr/share/leigod/config/
COPY opt/leigod/fake_os-release /etc/os-release
COPY docker/entrypoint.sh /usr/local/sbin/leigod-entrypoint
COPY docker/healthcheck.sh /usr/local/sbin/leigod-healthcheck
COPY docker/log-forwarder.sh /usr/local/sbin/leigod-log-forwarder

RUN chmod 0755 /opt/leigod/acc-gw.router.amd64 /usr/local/sbin/leigod-entrypoint \
        /usr/local/sbin/leigod-healthcheck /usr/local/sbin/leigod-log-forwarder \
    && mkdir -p /opt/leigod /var/lib/leigod /home \
    && ln -s /var/lib/leigod/config /opt/leigod/config \
    && ln -s /opt/leigod /home/leigod \
    && printf '%s\n' "$LEIGOD_VERSION" > /usr/share/leigod/image-version

ENTRYPOINT ["/usr/local/sbin/leigod-entrypoint"]
