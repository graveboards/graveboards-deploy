#!/bin/sh
set -e

# Render prometheus.yml with environment variables (e.g., ${ENV:-dev})
if [ -f /etc/prometheus/prometheus.yml ]; then
    envsubst < /etc/prometheus/prometheus.yml > /etc/prometheus/prometheus.rendered.yml
fi

# Start prometheus with the rendered config
exec /bin/prometheus "$@"
