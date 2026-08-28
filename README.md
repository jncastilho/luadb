# LuaDB

**LuaDB** is a lightweight, embeddable, zero-dependency Relational Database Management System (RDBMS) written **100% from scratch in pure Lua** (compatible with Lua 5.1+, Lua 5.4, Lua 5.5, and LuaJIT).

It provides full SQL execution, Write-Ahead Logging (WAL) for ACID transactions, a B+Tree indexing engine, a pluggable Virtual File System (VFS) layer (**Local Disk**, **In-Memory RAM**, and **Amazon S3 Object Storage** with AWS SigV4 authentication), a **Native JSON/JSONB Engine**, a **PostgreSQL Wire Protocol Gateway**, **Multi-Region Master-Master Active-Active Cluster Replication**, **`ALTER TABLE` Schema Migrations**, **Foreign Key `ON DELETE CASCADE` Constraints**, and **Common Table Expressions (`WITH` CTEs)**.

---

## Key Features

- **Zero External Dependencies**: 100% pure Lua. Embed directly into LÖVE2D, Roblox, OpenResty, CLI applications, or embedded Linux environments.
- **Pluggable Storage Layer (VFS)**:
  - `local`: Direct disk storage using Lua binary `io`.
  - `memory`: High-throughput RAM storage for transient state and testing.
  - `s3`: Cloud object storage backed by AWS S3 with page caching and AWS SigV4 authentication.
- **B+Tree Indexing Engine**: Slotted 4KB binary pages, automatic secondary index maintenance on `INSERT`, `UPDATE`, and `DELETE`.
- **ACID Transactions**: Write-Ahead Logging (WAL) with `BEGIN`, `COMMIT`, and `ROLLBACK`.
- **Native JSON / JSONB Support**:
  - Sub-object extraction operator: `details->'address'`
  - Unquoted text scalar operator: `details->>'city'`
  - Chained path extractions and direct `WHERE` clause filtering on nested attributes.
- **Foreign Keys & Referential Integrity**:
  - `FOREIGN KEY (...) REFERENCES ... ON DELETE CASCADE` enforcement.
  - Full catalog persistence in WAL metadata across database restarts.
- **PostgreSQL Wire Protocol Server**:
  - Connect standard tools (`psql`, DBeaver, DataGrip, TablePlus) directly via the built-in Postgres v3.0 gateway (`bin/luadb_server.lua`).
- **Multi-Region Master-Master Cluster**:
  - Active-active node topology, persistent Hinted Handoff queueing for offline nodes, 24-hour TTL expiration logging, and automatic snapshot catch-up sync.

---

## Quickstart

### Installation
Clone the repository into your Lua project path:
```bash
git clone https://github.com/your-username/luadb.git
```

### Usage Example
```lua
local luadb = require("luadb")

-- Open database handle
local db = luadb.open({
    driver = "local",
    storage_path = "app.db"
})

-- Create schema with Foreign Key constraints
db:exec([[
CREATE TABLE departments (
    id INT PRIMARY KEY,
    name TEXT
);

CREATE TABLE employees (
    id INT PRIMARY KEY,
    name TEXT,
    dept_id INT,
    details JSONB,
    salary REAL,
    FOREIGN KEY (dept_id) REFERENCES departments(id) ON DELETE CASCADE
);
]])

-- Insert records
db:exec("INSERT INTO departments VALUES (1, 'Engineering');")
db:exec("INSERT INTO employees VALUES (101, 'Alice', 1, '{\"role\": \"Lead\", \"level\": 5}', 125000.0);")

-- Execute query with JSON extraction & CTE
local rows = db:exec([[
WITH eng_staff AS (
    SELECT name, salary, details->>'role' AS role
    FROM employees
    WHERE dept_id = 1
)
SELECT * FROM eng_staff WHERE salary > 100000;
]])

for _, row in ipairs(rows) do
    print(row.name, row.role, row.salary)
end

db:close()
```

---

## Interfaces & Server Modes

### 1. Interactive CLI (`bin/luadb_cli.lua`)
Run the interactive SQL console:
```bash
lua bin/luadb_cli.lua mydata.db
```
```text
luadb=> CREATE TABLE demo (id INT PRIMARY KEY, title TEXT);
luadb=> INSERT INTO demo VALUES (1, 'Hello World');
luadb=> SELECT * FROM demo;
+----+-------------+
| id | title       |
+----+-------------+
| 1  | Hello World |
+----+-------------+
luadb=> \dt
luadb=> \q
```

### 2. Standalone PostgreSQL Wire Server (`bin/luadb_server.lua`)
Start the network database server listening on port 5433:
```bash
luajit bin/luadb_server.lua mydata.db 5433
```
Connect using standard `psql`:
```bash
psql -h 127.0.0.1 -p 5433 -U postgres -d luadb
```

---

## Runnable Examples (`examples/`)

| Script | Driver | Description |
|---|---|---|
| [`examples/01_embedded_local.lua`](examples/01_embedded_local.lua) | Local Disk | Disk persistence, schema creation, FK `CASCADE`, and CRUD operations. |
| [`examples/02_embedded_memory.lua`](examples/02_embedded_memory.lua) | In-Memory | High-speed RAM database with JSONB extractions and CTE aggregation. |
| [`examples/03_embedded_s3.lua`](examples/03_embedded_s3.lua) | Amazon S3 | Cloud VFS storage initialization and page caching demonstration. |
| [`examples/04_standalone_server.lua`](examples/04_standalone_server.lua) | Server | Standalone database server process and connection handling. |
| [`examples/05_kamailio_cdr_drain.lua`](examples/05_kamailio_cdr_drain.lua) | Telecom Failover | SIP Call Detail Record (CDR) failover buffer: stores CDRs locally when Kafka is offline and drains them upon recovery. |

---

## Running Verification Suite

To run the complete test suite across standard Lua and LuaJIT:

```bash
lua tests/run_all.lua
luajit tests/run_all.lua
```

---

## Architecture Specification

For full technical specifications (slotted binary page structure, B+Tree split algorithm, replication frame format, and VFS internals), see [TECHNICAL_ARCHITECTURE.md](TECHNICAL_ARCHITECTURE.md).

---

## License

MIT License. Free for personal and commercial use.
