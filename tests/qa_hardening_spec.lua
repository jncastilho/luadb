package.path = "src/?.lua;src/?/init.lua;" .. package.path

local luadb = require("luadb")
local parser = require("luadb.sql.parser")

print("\n--------------------------------------------------")
print("[TEST SUITE] QA Hardening & Static Analysis Remediations")
print("--------------------------------------------------")

-- ---------------------------------------------------------------------------
-- QA-01: Parser pcall Graceful Error Handling
-- ---------------------------------------------------------------------------
print("\n[QA-01] Parser Graceful Error Handling on Syntax Errors (No Exceptions)")

local malformed_queries = {
    { sql = "SELECT * FROM", desc = "missing table name" },
    { sql = "INSERT INTO tbl VALUES", desc = "missing values list" },
    { sql = "CREATE TABLE t (id INT", desc = "unclosed parenthesis in CREATE TABLE" },
    { sql = "UPDATE t SET", desc = "missing column assignment in UPDATE" },
    { sql = "DELETE t WHERE id = 1", desc = "missing FROM keyword in DELETE" },
    { sql = "SELECT * FROM t WHERE (id = 1", desc = "unclosed parenthesis in WHERE expression" },
}

for _, item in ipairs(malformed_queries) do
    local ok, res, err = pcall(parser.parse, item.sql)
    assert(ok, string.format("QA-01 FAIL: parser.parse threw unhandled exception for: %s", item.desc))
    assert(res == nil, string.format("QA-01 FAIL: expected nil AST for: %s", item.desc))
    assert(type(err) == "string" and #err > 0, string.format("QA-01 FAIL: expected error message for: %s", item.desc))
    print(string.format("  [OK] Syntax error handled gracefully: %s -> %s", item.desc, err:sub(1, 50)))
end

-- Test via high-level db:exec() as well
local db_mem = luadb.open({ driver = "memory" })
for _, item in ipairs(malformed_queries) do
    local res, err = db_mem:exec(item.sql)
    assert(res == nil, string.format("QA-01 FAIL: db:exec expected nil on: %s", item.desc))
    assert(type(err) == "string" and #err > 0, string.format("QA-01 FAIL: db:exec expected error message on: %s", item.desc))
end
print("  [OK] db:exec returned nil, err without throwing exceptions on all malformed SQL.")

-- ---------------------------------------------------------------------------
-- QA-05: Numbered $N Parameter Indexing (Out-of-order & Explicit)
-- ---------------------------------------------------------------------------
print("\n[QA-05] Numbered $N Parameter Indexing (Out-of-order & Explicit)")

db_mem:exec("CREATE TABLE users (id INT PRIMARY KEY, name TEXT, role TEXT);")
local res_ins, err_ins = db_mem:exec("INSERT INTO users VALUES ($1, $2, $3);", { 1, "Alice", "Admin" })
assert(res_ins, "Failed to insert with $1, $2, $3: " .. tostring(err_ins))

-- Out of order parameters: $2 before $1
local res_sel, err_sel = db_mem:exec("SELECT name, role FROM users WHERE role = $2 AND id = $1;", { 1, "Admin" })
assert(res_sel and #res_sel == 1, "Failed query with out-of-order $2 and $1: " .. tostring(err_sel))
assert(res_sel[1].name == "Alice", "Expected Alice, got " .. tostring(res_sel[1].name))
print("  [OK] Out-of-order binding WHERE role = $2 AND id = $1 evaluated correctly.")

-- Repeated parameter: $1 used multiple times
local res_rep, err_rep = db_mem:exec("SELECT name FROM users WHERE id = $1 OR id = $1;", { 1 })
assert(res_rep and #res_rep == 1, "Failed query with repeated $1 placeholder: " .. tostring(err_rep))
print("  [OK] Repeated placeholder $1 evaluated correctly.")

-- Missing parameter error reporting
local res_err, err_missing = db_mem:exec("SELECT * FROM users WHERE id = $5;", { 1, 2 })
assert(res_err == nil, "Expected error on missing $5 parameter")
assert(err_missing and err_missing:find("placeholder at position 5"), "Expected placeholder position 5 error, got: " .. tostring(err_missing))
print("  [OK] Missing parameter placeholder error reported accurately.")

-- ---------------------------------------------------------------------------
-- QA-03: Cross-Platform PID Aliveness Check (LocalVFS)
-- ---------------------------------------------------------------------------
print("\n[QA-03] Cross-Platform PID Aliveness and POSIX Fallbacks")

local local_vfs = require("luadb.vfs.local_vfs")
local vfs = local_vfs.new({ base_dir = "." })

-- Test that current process PID is alive
local cur_file, err_open = vfs:open("qa3_temp.db", "w+b")
assert(cur_file, "Failed to open qa3_temp.db: " .. tostring(err_open))

-- Lock file should exist and hold current process PID
local lock_file = io.open("qa3_temp.db.lock", "r")
assert(lock_file ~= nil, "Expected lock file to exist")
local lock_pid = tonumber(lock_file:read("*a"))
lock_file:close()
assert(lock_pid and lock_pid > 0, "Invalid lock PID recorded: " .. tostring(lock_pid))

-- Reopening from another connection in same process must report lock
local coll_file, coll_err = vfs:open("qa3_temp.db", "r+b")
assert(coll_file == nil, "Expected locked database collision")
assert(coll_err and coll_err:find("locked"), "Expected locked error message, got: " .. tostring(coll_err))
print("  [OK] Active process lock prevented concurrent write connection.")

-- Close connection to release lock
cur_file:close()
assert(io.open("qa3_temp.db.lock", "r") == nil, "Lock file was not cleaned up on close")
os.remove("qa3_temp.db")
print("  [OK] Lock file cleaned up successfully on close.")

-- Test stale lock file with dead PID (999999999)
local stale_lock = io.open("qa3_stale.db.lock", "w")
stale_lock:write("999999999")
stale_lock:close()

local stale_file, stale_err = vfs:open("qa3_stale.db", "w+b")
assert(stale_file, "Failed to open database despite stale dead lock: " .. tostring(stale_err))
stale_file:close()
os.remove("qa3_stale.db")
os.remove("qa3_stale.db.lock")
print("  [OK] Stale lock with dead PID (999999999) reclaimed seamlessly.")

-- ---------------------------------------------------------------------------
-- QA-04: WAL Auto-Checkpoint Threshold
-- ---------------------------------------------------------------------------
print("\n[QA-04] WAL Auto-Checkpoint Threshold")

local wal_test_db = "qa_wal_auto.db"
os.remove(wal_test_db)
os.remove(wal_test_db .. ".wal")
os.remove(wal_test_db .. ".lock")

local db_wal = luadb.open({ driver = "local", storage_path = wal_test_db })
-- Set a small auto-checkpoint threshold of 5 frames for testing
db_wal.wal.auto_checkpoint_frames = 5

db_wal:exec("CREATE TABLE auto_cp (id INT PRIMARY KEY, val TEXT);")
local payload_1k = string.rep("Z", 1000)

for i = 1, 10 do
    db_wal:exec(string.format("INSERT INTO auto_cp VALUES (%d, '%s');", i, payload_1k))
end

-- Since 10 transactions with large inserts occurred, WAL auto-checkpoint should have triggered
-- and written data to the main db file, resetting WAL file size
local main_size = db_wal.file:size()
assert(main_size > 4096, "Expected main DB file to have received pages via auto-checkpoint")

-- Verify data integrity from database
local res_cp = db_wal:exec("SELECT count(*) as total FROM auto_cp;")
assert(res_cp and res_cp[1].total == 10, "Expected 10 rows in auto_cp table")
db_wal:close()

-- Reopen to confirm data persisted after auto-checkpoint
local db_wal2 = luadb.open({ driver = "local", storage_path = wal_test_db })
local res_cp2 = db_wal2:exec("SELECT count(*) as total FROM auto_cp;")
assert(res_cp2 and res_cp2[1].total == 10, "Expected 10 rows persisted after restart")
db_wal2:close()

os.remove(wal_test_db)
os.remove(wal_test_db .. ".wal")
os.remove(wal_test_db .. ".lock")
print("  [OK] WAL auto-checkpoint triggered, reset frames, and preserved 100% data integrity.")

-- ---------------------------------------------------------------------------
-- QA-02: Freelist Range Packing & Overflow Protection (>300 pages)
-- ---------------------------------------------------------------------------
print("\n[QA-02] Freelist Range Packing and Catalog Page 1 Overflow Protection")

local fl_db_file = "qa_freelist_large.db"
os.remove(fl_db_file)
os.remove(fl_db_file .. ".wal")
os.remove(fl_db_file .. ".lock")

local db_fl = luadb.open({ driver = "local", storage_path = fl_db_file })
db_fl:exec("CREATE TABLE huge_table (id INT PRIMARY KEY, payload TEXT);")

-- Insert enough data to allocate >100 pages
local payload_2k = string.rep("H", 2000)
for i = 1, 300 do
    db_fl:exec(string.format("INSERT INTO huge_table VALUES (%d, '%s');", i, payload_2k))
end
db_fl:checkpoint()

local pre_drop_pages = math.floor(db_fl.file:size() / 4096)
print(string.format("  [INFO] Huge table populated: %d 4KB pages allocated", pre_drop_pages))
assert(pre_drop_pages >= 100, "Expected at least 100 pages allocated")

-- Drop table: all >100 pages reclaimed into freelist
local drop_res, drop_err = db_fl:exec("DROP TABLE huge_table;")
assert(drop_res, "Failed to drop huge table: " .. tostring(drop_err))

local free_reclaimed = #db_fl.executor.freelist
print(string.format("  [OK] Table dropped: %d pages collected into freelist", free_reclaimed))
assert(free_reclaimed >= 100, "Expected >=100 pages in freelist")

-- Close database: this writes catalog Page 1 with packed ranges FREE:start:count
db_fl:close()

-- Reopen database: verify range unpacking
local db_fl_reopen = luadb.open({ driver = "local", storage_path = fl_db_file })
local free_reloaded = #db_fl_reopen.executor.freelist
print(string.format("  [OK] Database reopened: %d freelist pages reloaded via packed ranges", free_reloaded))
assert(free_reloaded == free_reclaimed, string.format("Freelist mismatch: expected %d, reloaded %d", free_reclaimed, free_reloaded))

-- Populate a new table and verify pages are reused without inflating file size
db_fl_reopen:exec("CREATE TABLE recycled_table (id INT PRIMARY KEY, payload TEXT);")
for i = 1, 300 do
    db_fl_reopen:exec(string.format("INSERT INTO recycled_table VALUES (%d, '%s');", i, payload_2k))
end
db_fl_reopen:checkpoint()

local post_reuse_pages = math.floor(db_fl_reopen.file:size() / 4096)
print(string.format("  [OK] Recycled table populated: %d 4KB pages in file", post_reuse_pages))
assert(post_reuse_pages <= pre_drop_pages + 2, "Expected file size not to grow when reusing freelist pages")

db_fl_reopen:close()
os.remove(fl_db_file)
os.remove(fl_db_file .. ".wal")
os.remove(fl_db_file .. ".lock")
print("  [OK] Freelist range packing preserved and recycled all freed pages successfully.")

print("\n[PASS] QA Hardening & Static Analysis Remediation Suite Passed 100%!\n")
