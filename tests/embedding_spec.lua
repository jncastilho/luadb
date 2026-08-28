package.path = "src/?.lua;src/?/init.lua;" .. package.path

local luadb = require("luadb")

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("ASSERT FAILED: [%s] Expected %s, got %s", msg or "test", tostring(expected), tostring(actual)))
    else
        print(string.format("  ✓ [OK] %s: %s", msg or "check", tostring(actual)))
    end
end

print("\n--------------------------------------------------")
print("[TEST SUITE] Embedded Application API Integration")
print("--------------------------------------------------")

-- 1. Test In-Memory Embedded Session
print("\n[Embedding Test 1] In-Memory Embedded Session (luadb.open)")
local db_mem = luadb.open({ driver = "memory" })
db_mem:exec("CREATE TABLE players (id INTEGER PRIMARY KEY, name TEXT, level INTEGER);")

local stmt = db_mem:prepare("INSERT INTO players VALUES (?, ?, ?);")
stmt:exec(101, "PlayerOne", 50)
stmt:exec(102, "PlayerTwo", 75)

local level_sum = db_mem:exec("SELECT SUM(level) FROM players;")
assert_eq(level_sum[1].sum_level, 125, "In-Memory Embedded Query Result")
db_mem:close()

-- 2. Test Local File Embedded Session
print("\n[Embedding Test 2] Local File Embedded Session (luadb.open)")
os.remove("embedded_local.db")
local db_file = luadb.open({ driver = "local", storage_path = "embedded_local.db" })
db_file:exec("CREATE TABLE settings (key TEXT PRIMARY KEY, val TEXT);")
db_file:exec("INSERT INTO settings VALUES ('theme', 'dark');")
db_file:close()

-- Re-open session to verify persistence
local db_file_reopen = luadb.open({ driver = "local", storage_path = "embedded_local.db" })
local res_setting = db_file_reopen:exec("SELECT val FROM settings WHERE key = 'theme';")
assert_eq(res_setting[1].val, "dark", "Local File Embedded Session Persistence")
db_file_reopen:close()
os.remove("embedded_local.db")

-- 3. Test S3 Embedded Session Initialization
print("\n[Embedding Test 3] Amazon S3 Cloud Embedded Session (luadb.open)")
local db_s3 = luadb.open({
    driver = "s3",
    storage_path = "cloud_embedded.bin",
    s3 = {
        bucket = "my-test-bucket",
        region = "us-east-1",
        access_key = "AKIAEMBEDDED",
        secret_key = "secret_embedded_key"
    }
})
assert_eq(db_s3.vfs.bucket, "my-test-bucket", "S3 Embedded Bucket Config")
assert_eq(db_s3.vfs.region, "us-east-1", "S3 Embedded Region Config")

-- 4. Test Parallel Pool Embedded Session
print("\n[Embedding Test 4] Connection Pool Embedded Session (luadb.pool)")
os.remove("embedded_pool.db")
local pool = luadb.pool(2, { driver = "local", storage_path = "embedded_pool.db" })
pool.connections[1]:exec("CREATE TABLE queue (id INTEGER PRIMARY KEY, task TEXT);")

local p_res = pool:exec_parallel({
    "INSERT INTO queue VALUES (1, 'task_a');",
    "INSERT INTO queue VALUES (2, 'task_b');"
})
assert_eq(#p_res, 2, "Embedded Pool Execution Count")
pool:close()
os.remove("embedded_pool.db")

-- 5. Test Startup Auto-Recovery & Reindexing
print("\n[Embedding Test 5] Startup Auto-Recovery & Reindexing (REINDEX)")
os.remove("embedded_recovery.db")
local db_recovering = luadb.open({ driver = "local", storage_path = "embedded_recovery.db" })
db_recovering:exec("CREATE TABLE metrics (id INTEGER PRIMARY KEY, metric_name TEXT, val REAL);")
db_recovering:exec("CREATE INDEX idx_metric ON metrics (metric_name);")
db_recovering:exec("INSERT INTO metrics VALUES (1, 'cpu_load', 42.5);")
db_recovering:exec("INSERT INTO metrics VALUES (2, 'mem_used', 88.0);")
-- Simulate abrupt process termination
db_recovering = nil

-- Re-open session: engine auto-recovers WAL and rebuilds index trees on startup
local db_reopened = luadb.open({ driver = "local", storage_path = "embedded_recovery.db" })
local reindex_res = db_reopened:exec("REINDEX DATABASE;")
assert_eq(reindex_res.message, "Reindexed 1 index(es) successfully", "Startup Storage Reindexing Result")

local metric_rows = db_reopened:exec("SELECT val FROM metrics WHERE metric_name = 'cpu_load';")
assert_eq(metric_rows[1].val, 42.5, "Reindexed B+Tree Lookup Result")
db_reopened:close()
os.remove("embedded_recovery.db")

print("\n[PASS] Embedded Application API Suite Completed Successfully!")
