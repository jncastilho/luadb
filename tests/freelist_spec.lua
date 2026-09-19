package.path = "src/?.lua;src/?/init.lua;" .. package.path

local luadb = require("luadb")

print("\n--------------------------------------------------")
print("[TEST SUITE] Persistent Page Freelist & Space Reclamation")
print("--------------------------------------------------")

local db_file = "freelist_test.db"
os.remove(db_file)
os.remove(db_file .. ".wal")
os.remove(db_file .. ".lock")

-- 1. Create table and insert multi-page dataset
print("\n[Freelist Test 1] Populate Multi-Page Table")
local db = luadb.open({ driver = "local", storage_path = db_file })
db:exec("CREATE TABLE table_a (id INT PRIMARY KEY, content TEXT);")
local payload = string.rep("X", 250)

for i = 1, 100 do
    db:exec(string.format("INSERT INTO table_a VALUES (%d, '%s');", i, payload))
end

-- Checkpoint WAL into database file so we can inspect physical page allocations
db:checkpoint()

local size_a = db.file:size()
local pages_a = math.floor(size_a / 4096)
print(string.format("  ✓ [OK] Table A populated & checkpointed: %d bytes (~%d 4KB pages)", size_a, pages_a))
assert(pages_a >= 3, "Expected at least 3 pages allocated for 100 records")

-- 2. Drop table and verify pages are harvested into Freelist
print("\n[Freelist Test 2] Drop Table & Reclaim Pages into Freelist")
local free_before = #db.executor.freelist
db:exec("DROP TABLE table_a;")
local free_after = #db.executor.freelist

print(string.format("  ✓ [OK] Freelist count before: %d, after DROP: %d", free_before, free_after))
assert(free_after > free_before, "Expected pages to be reclaimed into freelist")

-- 3. Create a new table and populate it: must RECYCLE pages from Freelist
print("\n[Freelist Test 3] Reallocate New Table: Must Reuse Recycled Pages")
db:exec("CREATE TABLE table_b (id INT PRIMARY KEY, content TEXT);")

for i = 1, 100 do
    db:exec(string.format("INSERT INTO table_b VALUES (%d, '%s');", i, payload))
end

db:checkpoint()

local size_b = db.file:size()
local pages_b = math.floor(size_b / 4096)
print(string.format("  ✓ [OK] Table B populated & checkpointed: %d bytes (~%d 4KB pages)", size_b, pages_b))

-- Database size should NOT have doubled because pages were reused from freelist
assert(pages_b <= pages_a + 2, string.format("Freelist reuse failed: pages before=%d, after=%d (file grew without reusing free pages)", pages_a, pages_b))
print("  ✓ [OK] Page reuse verified: file did not grow redundantly")

-- 4. Verify Freelist persistence across restart
print("\n[Freelist Test 4] Verify Freelist Persistence Across Database Restart")
db:exec("DROP TABLE table_b;")
local free_count_pre_close = #db.executor.freelist
assert(free_count_pre_close > 0, "Expected free pages after DROP table_b")
db:close()

-- Reopen database
local db_reopened = luadb.open({ driver = "local", storage_path = db_file })
local free_count_post_open = #db_reopened.executor.freelist
print(string.format("  ✓ [OK] Freelist post-restart: %d pages ready for recycling", free_count_post_open))
assert(free_count_post_open == free_count_pre_close, string.format("Freelist catalog mismatch: expected %d, got %d", free_count_pre_close, free_count_post_open))

db_reopened:close()
os.remove(db_file)
os.remove(db_file .. ".wal")
os.remove(db_file .. ".lock")

print("\n[PASS] Persistent Page Freelist & Space Reclamation Suite Passed 100%!\n")
