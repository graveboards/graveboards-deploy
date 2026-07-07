#!/bin/sh
set -e

CONFIG_FILE="/etc/alertmanager/alertmanager.yml"
NULL_CONFIG="/etc/alertmanager/alertmanager-null.yml"
RENDERED="/tmp/alertmanager.rendered.yml"

if [ -n "${ALERTMANAGER_DISCORD_WEBHOOK_URL:-}" ]; then
  cp "$CONFIG_FILE" "$RENDERED"
  sed -i "s|\${ALERTMANAGER_DISCORD_WEBHOOK_URL}|${ALERTMANAGER_DISCORD_WEBHOOK_URL}|g" "$RENDERED"
else
  cp "$NULL_CONFIG" "$RENDERED"
fi

exec /bin/alertmanager --config.file="$RENDERED" "$@"
