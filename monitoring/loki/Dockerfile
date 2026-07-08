FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    wget \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=grafana/loki:latest /usr/bin/loki /usr/bin/loki
COPY --from=grafana/loki:latest /etc/loki /etc/loki
COPY --from=grafana/loki:latest /loki /loki

USER 10001
ENTRYPOINT ["/usr/bin/loki"]
