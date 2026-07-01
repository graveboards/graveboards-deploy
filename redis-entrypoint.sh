#!/bin/sh
# Redis entrypoint that conditionally enables authentication
# If REDIS_PASSWORD is set and non-empty, starts Redis with --requirepass
# Otherwise, starts Redis without authentication

if [ -n "${REDIS_PASSWORD:-}" ]; then
    echo "Starting Redis with password authentication"
    exec redis-server --requirepass "${REDIS_PASSWORD}" "$@"
else
    echo "Starting Redis without password authentication"
    exec redis-server "$@"
fi
