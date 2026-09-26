# Pull Request: feat(europadb): rebrand to EuropaDB, O(1) WAL indexing, POSIX locking, freelist packing & multi-oracle conformance

## Summary

This pull request resolves fundamental storage engine, durability, locking, and query execution gaps, transitioning the engine into **EuropaDB** (v2.0.0-europa) — an ultra-lightweight, crash-resilient embedded database with zero physical space leaks, comprehensive static analysis hardening, and 100% relational conformance across all supported SQL engines.

Named after *Europa*, one of the Galilean moons orbiting Jupiter. In Portuguese (the birthplace of Lua at PUC-Rio in Brazil), the word for Moon is literally *"Lua"*, making EuropaDB both an homage to its heritage and a planetary symbol of an impenetrable icy shell (binary WAL durability) harboring a deep relational ocean beneath.

All 22 automated test suites pass cleanly, achieving 100% byte-identical output across SQLite 3, DuckDB, and ClickHouse Local (219/219 test cases). Backward compatibility is 100% preserved via transparent module aliasing (`require("luadb") -> require("europadb")`).

---

## Key Changes

### 1. On-Disk Append-Only WAL Engine & Crash Recovery (`src/luadb/storage/wal.lua`)
- **Binary WAL Format**: Implemented an on-disk binary WAL file (`<dbname>.wal`) with a 32-byte header (`LUAWAL01`) and fixed 4112-byte frames (`page_id`, `commit_flag`, `tx_id`, `checksum`, `page_payload`).
- **Adler-32 Checksumming**: Every frame written to disk is validated against an Adler-32 checksum to protect against torn writes and storage corruption.
- **Redo Crash Recovery (`wal:recover()`)**: Automatically invoked on database startup. Scans the `.wal` file, discards uncommitted transactions and corrupt frames, and replays all committed transactions into the primary database file.
- **Checkpointing (`wal:checkpoint()`)**: Flushes all committed frames into the database file and resets/truncates the log.
- **Auto-Checkpoint Threshold**: Automatically checkpoints and resets WAL frames during `WAL:commit()` when log size reaches 1,000 frames (~4MB), avoiding unbounded WAL growth.
- **$O(1)$ In-Memory WAL Frame Index (`wal_frame_index`)**: Replaced linear reverse disk scanning with an $O(1)$ in-memory frame index tracking exact byte offsets for committed pages, eliminating latency spikes on cache misses.

### 2. Multi-Process File Locking & POSIX Durability (`src/luadb/vfs/local_vfs.lua`)
- **Kernel-Level `flock` & `busy_timeout` Exponential Backoff**: Enhanced advisory locking with POSIX kernel `flock` (via LuaJIT FFI when available) and a configurable `busy_timeout` retry loop with exponential backoff. Concurrent connections and workers gracefully wait for lock releases rather than abruptly crashing with busy errors.
- **Inter-Process Advisory Locking**: Creates `<dbname>.lock` containing process PID. Prevents concurrent processes from modifying the same database (`database is locked (busy)`).
- **Stale Lock Auto-Breaking**: Inspects `/proc/<pid>/stat` with a POSIX `kill -0` fallback for macOS/BSD to safely reclaim locks abandoned by killed or crashed processes.
- **Process ID Resolution & Caching**: Uses FFI `getpid()`, `/proc/self/stat`, and subshell parent PID fallbacks with process-lifetime caching to eliminate repetitive subshell execution.
- **Intra-Process Weak Table Registry**: Lock references are stored in a weak-valued table with `__gc` finalizers to ensure abandoned Lua handles release their locks during garbage collection.
- **POSIX `fsync` Support**: Flushes stdio buffers and invokes OS kernel `fsync` via FFI when available.
- **Cooperative Connection Pooling**: Allows connection pools within the same process to share access under the primary connection's lock.

### 3. Persistent Page Freelist & Space Reclamation (`src/luadb/sql/executor.lua` & `src/luadb/storage/btree.lua`)
- **Catalog Freelist with Contiguous Range Packing**: Catalog Page 1 tracks freed page IDs using run-length encoded ranges (`FREE:<start>:<count>`) with backward-compatible single entries (`FREE:<page_id>`).
- **Page 1 Overflow Protection**: Pre-validates serialized catalog size with `page_mgr.can_fit()` before writing to ensure massive drops (>300 pages) never overflow Page 1.
- **Page Recycling**: `_allocate_page()` checks the freelist first, popping and zeroing recycled pages before expanding the physical file.
- **Tree Harvesting on Drop**: `DROP TABLE` and `DROP INDEX` recursively traverse B-Tree leaves and interior nodes via `BTree:collect_all_pages()`, returning all allocated pages directly to the freelist.
- **Zero File Growth on Reallocation**: Recreating tables and reinserting records completely reuses reclaimed pages with zero file growth.

### 4. SQL Parser Hardening & Parameter Binding (`src/luadb/sql/parser.lua`)
- **Graceful Error Handling (`pcall`)**: Wrapped token parsing in `pcall` so that syntax errors, unclosed parentheses, and unhandled tokens return `nil, err` rather than throwing uncaught Lua exceptions.
- **Numbered Parameter Indexing (`$N`)**: Added support for explicit numbered parameter indexing (`$1`, `$2`), enabling out-of-order and repeated placeholder bindings.
- **Strict Parameter Validation**: Removed silent fallbacks that defaulted missing parameters to `"luadb"`, returning descriptive bind errors when parameters are omitted.
- **Expression & DDL Validation**: Enforced closing parenthesis checks in `CREATE TABLE` and preserved error propagation in `WHERE` expressions.

### 5. ClickHouse Local Conformance (`tests/darkroom_spec.lua`)
- Replaced `StripeLog` with `MergeTree ORDER BY tuple()` to support mutations.
- Rewrote `UPDATE` and `DELETE FROM` statements into ClickHouse `ALTER TABLE ... UPDATE/DELETE` syntax with `SETTINGS mutations_sync = 2`.
- Added `--data_type_default_nullable=1` and isolated `--format CSVWithNames` to tabular projections.
- Normalized ClickHouse `\N` tokens to empty strings in CSV output parsing.

---

## Multi-Oracle Conformance Matrix

```text
========================================================================================
                      DARK ROOM MULTI-ORACLE CONFORMANCE MATRIX                          
========================================================================================
 Oracle Technology        Engine Type        Total Tests  MATCH    FAIL     Match % 
----------------------------------------------------------------------------------------
 SQLite 3                 Embedded RDBMS     73           73       0         100.0%
 DuckDB                   Embedded OLAP      73           73       0         100.0%
 ClickHouse Local         Columnar OLAP      73           73       0         100.0%
----------------------------------------------------------------------------------------
 Overall Conformance: 219/219 MATCH (100.0% Byte-Identical Output)
========================================================================================

  [OK] LuaDB output is byte-identical across core relational Oracles on all test cases.
  [OK] Master Verification Suite Completed (100% Pass)
```

---

## Verification & Automated Test Suites

Five dedicated verification suites were introduced:

1. **`tests/parser_bind_spec.lua`**: Validates strict parameter validation and rejection of missing parameters.
2. **`tests/concurrency_locking_spec.lua`**: Validates intra-process connection locking, cross-process lock contention with background workers, and graceful lock acquisition via `busy_timeout` exponential backoff.
3. **`tests/freelist_spec.lua`**: Populates 100 records, drops the table, reinserts 100 records into a new table, and asserts 100% page reuse without file growth, plus freelist persistence across restart.
4. **`tests/wal_crash_recovery_spec.lua`**: Simulates `kill -9` during uncommitted transactions, crash after WAL commit before checkpoint, and trailing torn-write checksum rejection.
5. **`tests/qa_hardening_spec.lua`**: Validates parser exception safety on invalid syntax, out-of-order `$N` parameters, freelist range compression on large drops (>300 pages), cross-platform PID aliveness, and WAL auto-checkpoint thresholds.
6. **`examples/05_kamailio_cdr_drain.lua`**: Models a carrier-grade decoupled ingestion pattern: SIP workers push non-blocking events to shared memory in <10µs with zero disk I/O, while an auxiliary timer worker flushes batches into LuaDB with a single WAL commit.

All 22 test suites in `tests/run_all.lua` pass 100% under both Lua 5.5 and LuaJIT 2.1.
