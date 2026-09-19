# LuaDB Makefile
# ──────────────────────────────────────────────────────────────────────────────
#
# Targets:
#   make test            - Run the full in-process test suite (no Docker needed)
#   make test-compat     - Spin up CockroachDB + DynamoDB Local, run darkroom,
#                          then tear down. Requires Docker + cockroach CLI.
#   make oracles-up      - Start oracle containers only (leave running)
#   make oracles-down    - Stop and remove oracle containers + volumes
#   make cockroach-shell - Open an interactive CockroachDB SQL shell
#   make help            - Print this help

.PHONY: test test-compat oracles-up oracles-down cockroach-shell help

# ── In-process test suite ─────────────────────────────────────────────────────
test:
	lua tests/run_all.lua

# ── Full compatibility suite with live oracles ─────────────────────────────────
# Requires:
#   - Docker Engine (with Compose v2 plugin)
#   - cockroach CLI on PATH (or install via scripts/install-cockroach.sh)
test-compat: oracles-up
	@echo ""
	@echo "══════════════════════════════════════════════════════════════"
	@echo "  Running LuaDB Dark Room multi-oracle conformance suite..."
	@echo "══════════════════════════════════════════════════════════════"
	lua tests/darkroom_spec.lua
	@$(MAKE) oracles-down
	@echo ""
	@echo "[OK] Conformance suite complete."

# ── Oracle lifecycle ──────────────────────────────────────────────────────────
oracles-up:
	@echo "[oracles-up] Starting CockroachDB + DynamoDB Local..."
	docker compose up -d
	@echo "[oracles-up] Waiting for CockroachDB to accept SQL connections..."
	@./scripts/wait-for-cockroach.sh 90
	@echo "[oracles-up] All oracles ready."

oracles-down:
	@echo "[oracles-down] Stopping oracle containers..."
	docker compose down -v
	@echo "[oracles-down] Done."

# ── Interactive CockroachDB shell ─────────────────────────────────────────────
cockroach-shell:
	cockroach sql --insecure --host=127.0.0.1:26257

# ── Help ──────────────────────────────────────────────────────────────────────
help:
	@grep -E '^[a-zA-Z_-]+:.*?#.*$$' $(MAKEFILE_LIST) | \
	  awk 'BEGIN {FS = ":.*?# "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  See README.md or docker-compose.yml for full details."
