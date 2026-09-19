#!/usr/bin/env bash
# wait-for-cockroach.sh
# Polls CockroachDB until it accepts SQL queries, then exits 0.
# Usage: ./scripts/wait-for-cockroach.sh [max_seconds]
set -euo pipefail

MAX="${1:-60}"
HOST="127.0.0.1"
PORT="26257"
ELAPSED=0

echo "[wait-for-cockroach] Waiting up to ${MAX}s for CockroachDB at ${HOST}:${PORT}..."

# Try the cockroach binary first (fastest, gives real SQL handshake)
if command -v cockroach &>/dev/null; then
    while [ "$ELAPSED" -lt "$MAX" ]; do
        if cockroach sql --insecure --host="${HOST}:${PORT}" \
               -e "SELECT 1 AS result;" --format=csv 2>/dev/null \
               | grep -q "result"; then
            echo "[wait-for-cockroach] CockroachDB is ready (${ELAPSED}s elapsed)."
            exit 0
        fi
        sleep 2
        ELAPSED=$((ELAPSED + 2))
    done
else
    # Fallback: TCP-level port probe via /dev/tcp
    while [ "$ELAPSED" -lt "$MAX" ]; do
        if (echo > /dev/tcp/${HOST}/${PORT}) 2>/dev/null; then
            sleep 3
            echo "[wait-for-cockroach] CockroachDB port open (${ELAPSED}s elapsed)."
            exit 0
        fi
        sleep 2
        ELAPSED=$((ELAPSED + 2))
    done
fi

echo "[wait-for-cockroach] ERROR: CockroachDB did not become ready within ${MAX}s." >&2
exit 1
