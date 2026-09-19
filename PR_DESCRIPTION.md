# Pull Request: perf+fix+feat: O(log n) storage ops, lazy catalog flush, robust darkroom oracles, CockroachDB Docker infra

## Summary

This PR delivers a set of targeted correctness fixes and performance optimisations across the storage engine, SQL executor, and the darkroom conformance harness, plus new Docker infrastructure for full CockroachDB compatibility testing.

All existing test suites pass after every change:
> SQLite 3: 73/73 PASS | DuckDB: 73/73 PASS | Examples: 100% PASS | Benchmarks PASS

---

## Changes

### Bug Fixes

**`tests/darkroom_spec.lua` — CockroachDB false-positive oracle detection**

The connectivity pre-check used `cout:find("1")` to determine if CockroachDB was reachable. This matched the digit `1` inside the connection-refused error string (`"127.0.0.1:26257"`), causing CockroachDB to be registered as an active oracle even when the server was down — then failing all 73 of its tests and tripping the hard `error()` at the end.

Fix: the pre-check now uses `SELECT 1 AS result` and matches the CSV column header `"result"` (plus explicit guards for `"connection refused"` and `"dial error"`). The same fix is applied to the PostgreSQL pre-check. CockroachDB remains a full relational oracle in the `rel_fail` assertion.

---

### Performance Optimisations

**`storage/btree.lua` — O(log n) binary search on leaf pages**

`_find_in_node` and `_delete_from_node` both did O(n) linear scans over leaf items. Since the insert path already maintains items in sorted order, both paths now use binary search. Delete also avoids the `table.insert(new_items)` loop — it binary-searches for the index and calls `table.remove(items, idx)` directly.

**`storage/page.lua` — Single-pass serialization via `write_items_if_fits`**

The insert path previously called `can_fit(items)` then `write_items(items)` back-to-back, serializing every item twice on every non-split insert. A new `write_items_if_fits()` function serializes once into a buffer, returns the buffer on success or `nil` on overflow. `btree._insert_into_node` now uses it.

**`sql/executor.lua` — FK validation skips full table scan for PK references**

Every FK-constrained `INSERT` previously did a full `btree:scan()` of the parent table. The new path checks in priority order:

1. O(log n) — `btree:find(fk_val)` when the referenced column is the parent PK (the overwhelming majority of real-world FKs)
2. O(log n) — secondary index lookup if one exists on the referenced column
3. O(n) — full scan as an explicit last resort for non-indexed non-PK references

**`sql/executor.lua` — Lazy `_save_catalog()` via `_catalog_dirty` flag**

`_save_catalog()` was called on every `INSERT`, rewriting the entire catalog B+Tree page just to persist an incremented `auto_inc`. It is now deferred:

- Inside `BEGIN`/`COMMIT` transactions: flushed atomically on `COMMIT`
- Autocommit INSERTs: flushed immediately (same net durability, zero overhead for batched transactional inserts)
- `ROLLBACK`: `_catalog_dirty` is cleared without any write

**`sql/executor.lua` — Remove `reindex()` from cold start**

`executor.new()` called `reindex()` on every process startup, allocating new page IDs and scanning all table rows for every secondary index. Index `root_page_id`s are already persisted in the catalog and loaded by `_load_catalog()`. The startup call is removed; `REINDEX` SQL still works explicitly.

---

### Correctness Fix

**`storage/serializer.lua` — Remove heuristic JSON type tag**

`pack_value()` applied binary tag `0x05` (JSON) to any string whose first and last characters were `{`/`}` or `[`/`]`. This silently mis-tagged ordinary strings like `"[deprecated]"` or `"{id}"`. Since both `0x04` and `0x05` round-trip as Lua strings on unpack, the distinction had no semantic benefit. The heuristic is removed. Lua table values still get `0x05` correctly via the table branch.

---

### Infrastructure

**`docker-compose.yml`** — Brings up:

- `cockroachdb/cockroach:v23.2.3` on `127.0.0.1:26257` (insecure, single-node) — exact match for darkroom's `--insecure --host=127.0.0.1:26257`
- `amazon/dynamodb-local:2.4.0` on `127.0.0.1:8000`
- Both services include Docker healthchecks

**`scripts/wait-for-cockroach.sh`** — Polls until CockroachDB accepts SQL (cockroach CLI, falls back to `/dev/tcp` probe). Used by `make test-compat`.

**`scripts/install-cockroach.sh`** — Downloads the cockroach v23.2.3 CLI binary to `~/.local/bin` for Linux and macOS (amd64 + arm64).

**`Makefile`** — Targets: `test`, `test-compat`, `oracles-up`, `oracles-down`, `cockroach-shell`.

**`.gitignore`** — Added: Docker volume dirs, profiler dump dirs, darkroom temp DB files.

---

## Test Evidence

```
 Oracle Technology   Tests   MATCH   FAIL   Match%
 SQLite 3            73      73      0      100.0%
 DuckDB              73      73      0      100.0%
 ClickHouse Local    73      29      44      39.7%  (structural: no mutation support)

 [OK] LuaDB output is byte-identical across core relational Oracles on all test cases.
 [PASS] LuaDB Performance & Memory Metrics Completed Successfully!
 [PASS] Runnable Examples Suite Passed 100%!
```
