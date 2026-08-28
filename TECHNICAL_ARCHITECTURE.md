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
|    (Recursive Descent AST / CTE / Subqueries / ALTER / JSON -> & ->> / Types)   |
+-------------------------------------------------------------------------------+
                                       |
                                       v
+-------------------------------------------------------------------------------+
|                            Query Execution Engine                             |
|    (B+Tree Lookups / Secondary Indexes / FK CASCADE / Transactions / WAL)     |
+-------------------------------------------------------------------------------+
                         |                               |
                         v                               v
+---------------------------------+             +-------------------------------+
|      Multi-Region Replication    |             |  Fixed 4KB Slotted Page Engine|
| (Hinted Handoff / 24h TTL Log)  |             | (Type Tags: Int/Float/Text/JSON)|
+---------------------------------+             +-------------------------------+
                                                         |
                                                         v
+-------------------------------------------------------------------------------+
|                          Pluggable VFS Storage Layer                          |
|             +--------------------+-------------------+------------------+     |
|             | Local Disk (POSIX) | RAM (MemoryVFS)   | Amazon S3 (SigV4)|     |
|             +--------------------+-------------------+------------------+     |
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
| Byte 2..5: Slot Count (UInt32)                                               |
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

#### B+Tree Maintenance (`storage/btree.lua`):
- **Leaf Split**: When a leaf page exceeds 4096 bytes, it splits into two leaf pages and promotes the median boundary key to an interior parent page.
- **Interior Traversal**: Interior pages direct binary search down child page pointers.
- **Secondary Indexing**: Secondary B+Trees map indexed column values to primary key IDs and automatically update on `INSERT`, `UPDATE`, and `DELETE`.

---

### 2.3. Write-Ahead Logging (WAL) & ACID Transactions
- **WAL Engine (`storage/wal.lua`)**: In-progress mutations are held in uncommitted page buffers (`pending_pages`).
- **`BEGIN`**: Enables page buffer isolation.
- **`COMMIT`**: Flushes pending pages sequentially to VFS and issues `sync()`.
- **`ROLLBACK`**: Discards uncommitted page buffers.

---

### 2.4. SQL Lexer, Parser & Executor

#### Lexical Analyzer (`sql/lexer.lua`)
Tokenizes raw SQL into structured token streams supporting standard SQL keywords, JSON operators (`->`, `->>`), parameters (`?`, `$1`), and SQL-standard quote escaping (`''`).

#### Parser (`sql/parser.lua`)
Recursive-descent parser building AST representations for:
- DDL: `CREATE TABLE`, `CREATE INDEX`, `DROP TABLE`, `DROP INDEX`, `ALTER TABLE (ADD COLUMN / RENAME TO)`.
- DML: `SELECT` (projections, aggregates, JOINs, WHERE, ORDER BY, LIMIT), `INSERT`, `UPDATE`, `DELETE`.
- Transactions: `BEGIN`, `COMMIT`, `ROLLBACK`.
- CTEs: `WITH cte_name AS (...) SELECT ...`.

#### Query Executor (`sql/executor.lua`)
- **Referential Integrity**: Checks Foreign Key constraints on `INSERT`/`UPDATE` and executes `ON DELETE CASCADE` removals.
- **Catalog WAL Persistence**: Packs Foreign Key definitions and column metadata into Catalog Page 1 (`TBL:<name>`), persisting constraints across database restarts.

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
- **Protocol Framing (`cluster/proto.lua`)**: Binary replication packet serialization (`'R'` replication, `'A'` ACK).
- **Replication Engine (`cluster/replicator.lua`)**:
  - Non-blocking socket broadcast to peer nodes.
  - **Hinted Handoff Queue**: Offline peer mutations are buffered in persistent memory queues.
  - **24-Hour TTL Expiration**: Unreachable peers transition to `STALE_EXPIRED` state and expired items move to `pg_failed_replication_log`.
  - **Snapshot Catch-Up Sync**: Automatically syncs full table data when a stale node recovers.

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
│   ├── init.lua               # Main package entry point (luadb.open / luadb.pool)
│   ├── async/                 # Scheduler & connection pool
│   ├── cluster/               # Master-master active-active replication & config
│   ├── net/                   # PostgreSQL wire protocol socket gateway
│   ├── sql/                   # Lexer, Parser, Executor, and JSON engine
│   ├── storage/               # B+Tree, WAL, Slotted Page Manager, Serializer
│   └── vfs/                   # Local, Memory, and S3 SigV4 VFS drivers
├── tests/                     # 12-suite master verification framework
│   └── run_all.lua
├── README.md                  # Project overview & quickstart
└── TECHNICAL_ARCHITECTURE.md # Architecture specification
```
