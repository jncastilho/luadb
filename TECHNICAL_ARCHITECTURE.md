# LuaDB Technical Architecture Specification

**LuaDB** is a lightweight, zero-dependency, embeddable Relational Database Management System (RDBMS) written **100% from scratch in pure Lua** (compatible with Lua 5.1+, 5.4, 5.5, and LuaJIT).

---

## 1. System Architecture Overview

```text
+-------------------------------------------------------------------------------+
|                       Applications / Drivers / CLI                            |
|        (Lua API: luadb.open / PostgreSQL Wire Gateway: port 5433 / CLI)        |
+-------------------------------------------------------------------------------+
                                       |
                                       v
+-------------------------------------------------------------------------------+
|                             SQL Parser & Lexer                                |
|  (Recursive Descent AST / CTE / GROUP BY / ORDER BY / OFFSET / NULL / JSON)  |
+-------------------------------------------------------------------------------+
                                       |
                                       v
+-------------------------------------------------------------------------------+
|                            Query Execution Engine                             |
|  (B+Tree / Secondary Indexes / FK CASCADE / Transactions / WAL / GROUP BY)   |
+-------------------------------------------------------------------------------+
                         |                               |
                         v                               v
+---------------------------------+             +-------------------------------+
|  Multi-Region Replication       |             |  Fixed 4KB Slotted Page Engine|
|  Real HLC State (pt, lc)        |             |  (NULL/Bool/Int/Float/Text/JSON|
|  State Export/Import            |             |   Binary Type Tags 0x00-0x05) |
|  (Hinted Handoff / 24h TTL Log) |             +-------------------------------+
+---------------------------------+                              |
                                                                 v
+-------------------------------------------------------------------------------+
|                          Pluggable VFS Storage Layer                          |
|             +--------------------+-------------------+------------------+     |
|             | Local Disk (POSIX) | RAM (MemoryVFS)   | Amazon S3 (SigV4)|     |
|             +--------------------+-------------------+------------------+     |
+-------------------------------------------------------------------------------+
                                                         |
                                                         v
+-------------------------------------------------------------------------------+
|                     Dark Room Conformance Oracle (External)                   |
|                   sqlite3 CLI — Independent comparative testing               |
+-------------------------------------------------------------------------------+
```

---

## 2. Component Subsystems

### 2.1. Pluggable Virtual File System (VFS)
The VFS layer abstracts underlying physical persistence via a unified file interface (`open`, `read`, `write`, `sync`, `size`, `close`):

- **Local Disk Driver (`vfs/local_vfs.lua`)**: Uses binary file I/O for persistent disk storage.
- **In-Memory Driver (`vfs/memory_vfs.lua`)**: Pure Lua byte array buffer for zero-disk RAM storage.
- **Amazon S3 Driver (`vfs/s3_vfs.lua`)**: Object storage driver featuring:
  - AWS SigV4 request signing (`vfs/aws_sigv4.lua` using pure Lua `HMAC-SHA256`).
  - Page-based local dirty page caching and write-back synchronization.

---

### 2.2. Storage Engine & Page Format
All tables and indexes are stored in fixed **4096-byte slotted binary pages**:

```text
+-------------------------------------------------------------------------------+
| Byte 1: Page Type (1=Leaf, 2=Interior)                                        |
| Byte 2..5: Slot Count (UInt32)                                                |
| Byte 6..9: Next Page ID / Right Child ID (UInt32)                             |
| (Page Header = 9 Bytes)                                                       |
+-------------------------------------------------------------------------------+
| Byte 10..4096: Serialized Items (Key-Value Tuples / Child Pointers)           |
+-------------------------------------------------------------------------------+
```

#### Binary Type Tags (`storage/serializer.lua`):
- `0x00`: NULL
- `0x01`: FALSE
- `0x02`: TRUE
- `0x03`: NUMBER (IEEE 754 Double / Packed int)
- `0x04`: STRING
- `0x05`: JSON / JSONB

NULL columns are stored as tag `0x00` at their correct positional offset. The row length anchor (`row.n`) ensures nil holes are preserved through the serialization pipeline even when Lua's `#` operator would otherwise undercount sparse arrays.

#### B+Tree Maintenance (`storage/btree.lua`):
- **Leaf Split**: When a leaf page exceeds 4096 bytes, it splits into two leaf pages and promotes the median boundary key to an interior parent page.
- **Interior Traversal**: Interior pages direct binary search down child page pointers.
- **Secondary Indexing**: Secondary B+Trees map indexed column values to primary key IDs and automatically update on `INSERT`, `UPDATE`, and `DELETE`.

---

### 2.3. Write-Ahead Logging (WAL), Transaction Isolation & Crash Recovery
- **WAL Engine (`storage/wal.lua`)**: In-progress mutations are held in uncommitted page buffers (`pending_pages`).
- **`BEGIN`**: Enables page buffer isolation.
- **`COMMIT`**: Flushes pending pages sequentially to VFS and issues `sync()`.
- **`ROLLBACK`**: Discards uncommitted page buffers entirely.
- **`wal:recover()`**: Resets transient dirty memory buffers and syncs storage handles to ensure zero post-crash storage corruption (`tests/crash_recovery_spec.lua`).

---

### 2.4. SQL Lexer, Parser & Executor

#### Lexical Analyzer (`sql/lexer.lua`)
Tokenizes raw SQL into structured token streams supporting standard SQL keywords, JSON operators (`->`, `->>`), parameters (`?`, `$1`), and SQL-standard quote escaping (`''`).

#### Parser (`sql/parser.lua`)
Recursive-descent parser building AST representations for:
- **DDL**: `CREATE TABLE`, `CREATE INDEX`, `DROP TABLE`, `DROP INDEX`, `ALTER TABLE (ADD COLUMN / RENAME TO)`.
- **DML**: `SELECT` (projections, aggregates, JOINs, `WHERE`, multi-column `ORDER BY`, `GROUP BY`, `HAVING`, `LIMIT`, `OFFSET`), `INSERT`, `UPDATE`, `DELETE`.
- **Transactions**: `BEGIN`, `COMMIT`, `ROLLBACK`.
- **CTEs**: `WITH cte_name AS (...) SELECT ...`.

Key correctness details:
- `INSERT INTO ... VALUES (...)` uses **direct positional index assignment** (`values[i] = val`) with explicit length anchor (`.n`) to preserve `NULL` holes.
- `OFFSET` is parsed immediately after `LIMIT` and propagated into the AST.
- `ORDER BY` parses a comma-separated list of `(column, direction)` pairs, enabling multi-column sorting.
- `GROUP BY` parses a column list and optional `HAVING` clause.

#### Query Executor (`sql/executor.lua`)
- **Referential Integrity**: Checks Foreign Key constraints on `INSERT`/`UPDATE` and executes `ON DELETE CASCADE` removals.
- **Catalog WAL Persistence**: Packs Foreign Key definitions and column metadata into Catalog Page 1 (`TBL:<name>`), persisting constraints across database restarts.
- **ORDER BY evaluation order**: Sorting is applied to raw indexed rows **before** column projection, so `ORDER BY` columns not present in the `SELECT` list still sort correctly. Unknown `ORDER BY` column names return a SQL execution error.
- **GROUP BY**: Groups filtered rows using typed group key tags (`N` for NULL, `S:val` for strings, `I:val` for numbers, `B:val` for booleans), preventing `NULL` and empty string `''` collisions. Computes per-group aggregates (`COUNT(*)`, `COUNT(col)`, `SUM`, `AVG`, `MIN`, `MAX`).
- **Aggregate NULL Semantics**: `COUNT(*)` counts all rows in group; `COUNT(col)`, `AVG(col)`, `SUM(col)`, `MIN(col)`, `MAX(col)` exclude `NULL` values per standard SQL semantics.
- **LIMIT + OFFSET**: Applied as a slice of the final (sorted, projected) row set: `rows[offset+1 .. offset+limit]`.
- **LIKE**: Case-insensitive for ASCII characters, matching SQLite's default behaviour.
- **IS NULL / IS NOT NULL**: Evaluated against the deserialized column value; `NULL` columns deserialize to Lua `nil` (tag `0x00` in binary pages).

#### SQL Conformance
The `tests/darkroom_spec.lua` harness provides independent comparative test coverage by executing 50 SQL statements simultaneously against LuaDB and external `sqlite3` CLI and comparing results row-by-row. **Current result: 50/50 MATCH**.

---

### 2.5. PostgreSQL Wire Protocol Server (`net/pg_server.lua`)

Implements PostgreSQL v3.0 Server Gateway over non-blocking POSIX sockets (LuaJIT FFI):
- Handshake & Authentication (`SSLRequest` -> `'N'`, `StartupMessage` -> `AuthenticationOk`).
- ParameterStatus broadcast (`server_version=14.0`, `client_encoding=UTF8`).
- Simple Query (`'Q'`) & Extended Query (`'P'`, `'B'`, `'D'`, `'E'`, `'S'`) message loops.
- Specification-compliant `RowDescription` (`'T'`) and `DataRow` (`'D'`) message construction.

---

### 2.6. Multi-Region Active-Active Cluster Replication (`cluster/`)

- **Topology Parsing (`cluster/config.lua`)**: Environment topology discovery via `LUADB_NODES`.
- **Protocol Framing (`cluster/proto.lua`)**: Tuple HLC string representation (`pt:lc`) for network replication framing (`'R'` replication, `'A'` ACK).
- **Replication Engine (`cluster/replicator.lua`)**:
  - Non-blocking socket broadcast to peer nodes with full `send_all` TCP byte-streaming loops.
  - **Transaction Isolation**: Mutations inside open transactions (`BEGIN TRANSACTION`) are buffered in memory (`tx_pending_mutations`) and only replicated/persisted upon `COMMIT`. On `ROLLBACK`, uncommitted mutation queues are completely discarded.
  - **Multi-Row & Non-PK Mutation Tracking**: Query execution directly returns affected primary key lists (`affected_pks`) so multi-row `UPDATE` and `DELETE` queries with arbitrary `WHERE` clauses update HLC row versions for all modified records.
  - **Hinted Handoff Queue**: Offline peer mutations are buffered in persistent memory queues.
  - **24-Hour TTL Expiration**: Unreachable peers transition to `STALE_EXPIRED` state; expired items move to `pg_failed_replication_log`.
  - **Schema-Aware Snapshot Sync**: Uses table catalog metadata to resolve exact primary key column names when generating recovery snapshots for recovering nodes.

#### 2.6.1. HLC Conflict Resolution (`cluster/conflict.lua`)

In active-active (master-master) topologies, concurrent writes to the same row on different nodes create write conflicts. LuaDB resolves these using **Hybrid Logical Clocks (HLC)**:

- **HLC Clock Maintenance**: Maintains explicit clock state `{ pt = physical_us, lc = logical_counter }`:
  - `pt' = max(last_pt, physical_now, remote_pt)`
  - If `pt'` equals both local and remote timestamps, `lc'` increments: `max(last_lc, remote_lc) + 1`.
  - Clock state is updated on **both** local write generation and remote message receipt (`should_apply`), ensuring lagging nodes advance their clocks past received remote timestamps.
- **Canonical 3-Tier Total Ordering**: Deterministic total ordering comparator (`cmp_total`): `HLC physical time (pt)` -> `HLC logical counter (lc)` -> `node ID`.
- **State Export/Import & Automatic Persistence**: Conflict version maps and clock state are exported/imported and automatically persisted to catalog table `_luadb_conflict_state` on `COMMIT`, `db:close()`, and `receive_replication()`.
- **Conflict Observability**: Conflicts are logged and exposed via the virtual system table `pg_replication_conflicts`:

```sql
SELECT * FROM pg_replication_conflicts;
-- Returns: table_name, pk_val, winner_node, winner_ts, loser_node, loser_ts, reason, resolved_at
```

---

## 3. Directory Layout

```text
luadb/
├── bin/
│   ├── luadb_cli.lua          # Interactive SQL CLI shell
│   └── luadb_server.lua       # Standalone PostgreSQL wire protocol server
├── examples/                  # Self-contained runnable usage scripts
│   ├── 01_embedded_local.lua
│   ├── 02_embedded_memory.lua
│   ├── 03_embedded_s3.lua
│   ├── 04_standalone_server.lua
│   └── 05_kamailio_cdr_drain.lua
├── src/luadb/
│   ├── init.lua               # Main entry point (luadb.open / luadb.pool / db:gc / db:recover)
│   ├── async/                 # Scheduler & connection pool
│   ├── cluster/               # Master-master replication, HLC conflict resolution & config
│   │   ├── conflict.lua       # Real HLC state maintenance, LWW resolver & state export/import
│   │   ├── proto.lua          # Binary replication frame serialization
│   │   └── replicator.lua     # Broadcast engine, hinted handoff, TTL expiry, snapshot sync
│   ├── net/                   # PostgreSQL wire protocol socket gateway
│   ├── sql/                   # Lexer, Parser, Executor, and JSON engine
│   │   ├── executor.lua       # Query executor (COUNT(col), GROUP BY typed keys, ORDER BY validation)
│   │   ├── lexer.lua          # SQL tokenizer
│   │   ├── parser.lua         # Recursive-descent AST builder
│   │   └── json.lua           # JSON/JSONB storage and -> / ->> extraction
│   ├── storage/               # B+Tree, WAL, Slotted Page Manager, Serializer
│   │   ├── btree.lua          # B+Tree with leaf/interior split
│   │   ├── page.lua           # 4KB slotted binary page read/write
│   │   ├── serializer.lua     # Type-tagged binary value serializer (NULL-safe)
│   │   └── wal.lua            # Write-Ahead Log, BEGIN/COMMIT/ROLLBACK
│   └── vfs/                   # Local, Memory, and S3 SigV4 VFS drivers
├── tests/                     # 16-suite master verification framework
│   ├── darkroom_spec.lua      # 50-case comparative test vs external sqlite3 (50/50 MATCH)
│   ├── conflict_spec.lua      # HLC clock catch-up, LWW tie-break & state persistence
│   ├── crash_recovery_spec.lua # Deterministic WAL crash recovery fuzzing
│   ├── benchmark_spec.lua     # TPS, query latency, and memory footprint metrics
│   └── run_all.lua            # Master test runner
├── README.md                  # Project overview & quickstart
└── TECHNICAL_ARCHITECTURE.md  # This document
```

---

## 4. SQL Conformance Matrix

The following SQL features are verified by `tests/darkroom_spec.lua` against SQLite 3 as an independent oracle:

| Feature | Verified |
|---|---|
| `CREATE TABLE` / `DROP TABLE` | ✓ |
| `INSERT INTO ... VALUES (...)` with NULL columns | ✓ |
| `SELECT *` and column projection | ✓ |
| `WHERE` with `=`, `<`, `>`, `!=`, `AND`, `OR` | ✓ |
| `WHERE ... LIKE 'pattern%'` (case-insensitive) | ✓ |
| `WHERE ... IS NULL` / `IS NOT NULL` | ✓ |
| `ORDER BY col ASC/DESC` (single and multi-column) | ✓ |
| `ORDER BY` on non-projected columns | ✓ |
| `GROUP BY col` with `COUNT(*)`, `COUNT(col)`, `AVG()`, `SUM()` | ✓ |
| Aggregate NULL exclusion (`COUNT(col)`, `AVG` skip NULL rows) | ✓ |
| Typed `GROUP BY` separation of `NULL` and empty string `''` | ✓ |
| `LIMIT n OFFSET m` | ✓ |
| `UPDATE ... SET ... WHERE` | ✓ |
| `DELETE FROM ... WHERE` | ✓ |
| Transaction `ROLLBACK` atomicity | ✓ |
| INTEGER / REAL / TEXT data type round-trip | ✓ |
| Empty result set and no-match DML | ✓ |
