# Stage 1: Copy prometheus binary from official image
FROM prom/prometheus:latest AS prometheus-binary

# Stage 2: Build custom image with envsubst support
FROM alpine:latest

RUN apk add --no-cache gettext ca-certificates

COPY --from=prometheus-binary /bin/prometheus /bin/prometheus
COPY --from=prometheus-binary /bin/promtool /bin/promtool

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

WORKDIR /prometheus

ENTRYPOINT ["/entrypoint.sh"]
CMD ["--config.file=/etc/prometheus/prometheus.rendered.yml", "--storage.tsdb.path=/prometheus"]
