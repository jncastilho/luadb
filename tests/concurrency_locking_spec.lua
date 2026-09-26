package.path = "src/?.lua;src/?/init.lua;" .. package.path

local luadb = require("luadb")

print("\n--------------------------------------------------")
print("[TEST SUITE] Multi-Process & Connection File Locking Suite")
print("--------------------------------------------------")

local db_file = "lock_test.db"
os.remove(db_file)
os.remove(db_file .. ".wal")
os.remove(db_file .. ".lock")

-- 1. Open primary connection
print("\n[Locking Test 1] Primary Connection Obtains Exclusive Lock")
local db1 = luadb.open({ driver = "local", storage_path = db_file })
db1:exec("CREATE TABLE test_lock (id INT PRIMARY KEY, val TEXT);")
db1:exec("INSERT INTO test_lock VALUES (1, 'initial');")
print("  ✓ [OK] Connection 1 opened and holding database lock")

-- 2. Secondary connection in same process must be rejected with busy error
print("\n[Locking Test 2] Concurrent Connection Blocked by Lock")
local ok, err = pcall(function()
    return luadb.open({ driver = "local", storage_path = db_file })
end)
assert(ok == false, "Expected second open to fail due to active lock")
assert(tostring(err):find("locked %(busy"), "Expected 'locked (busy)' in error, got: " .. tostring(err))
print("  ✓ [OK] Connection 2 blocked with expected error: " .. tostring(err):gsub("\n", " "))

-- 3. Primary connection closes, lock is released cleanly
print("\n[Locking Test 3] Connection 1 Closes & Releases Lock")
db1:close()

-- 4. Connection 2 now successfully acquires lock
print("\n[Locking Test 4] Connection 2 Acquires Released Lock")
local db2 = luadb.open({ driver = "local", storage_path = db_file })
local rows = db2:exec("SELECT * FROM test_lock;")
assert(#rows == 1 and rows[1].val == "initial", "Expected row 'initial' intact")
print("  ✓ [OK] Connection 2 opened cleanly and verified data integrity")
db2:close()

-- 5. Inter-process lock simulation
print("\n[Locking Test 5] Inter-Process Lock Contention")
-- Start external background process that holds lock for 1 second
local bg_cmd = string.format("lua -e 'package.path=\"src/?.lua;src/?/init.lua;\"..package.path; local db=require(\"luadb\").open({driver=\"local\", storage_path=\"%s\"}); os.execute(\"sleep 1\"); db:close()' &", db_file)
os.execute(bg_cmd)
-- Sleep 100ms to allow background process to acquire lock
os.execute("sleep 0.2")

local bg_ok, bg_err = pcall(function()
    return luadb.open({ driver = "local", storage_path = db_file })
end)
assert(bg_ok == false, "Expected open to fail while external background process holds lock")
assert(tostring(bg_err):find("locked %(busy"), "Expected busy lock error, got: " .. tostring(bg_err))
print("  ✓ [OK] External process lock contention verified: " .. tostring(bg_err):gsub("\n", " "))

-- Wait for background process to finish and release lock
os.execute("sleep 1.2")

-- Should now be able to open successfully
local db3 = luadb.open({ driver = "local", storage_path = db_file })
local r3 = db3:exec("SELECT count(*) AS cnt FROM test_lock;")
assert(#r3 == 1, "Expected query to succeed post-external release")
print("  ✓ [OK] Reacquired lock cleanly after external process exited")
db3:close()

-- 6. Test busy_timeout waiting for lock release
print("\n[Locking Test 6] busy_timeout Graceful Waiting & Acquisition")
-- Start external background process that holds lock for 0.4s
local bg_cmd2 = string.format("lua -e 'package.path=\"src/?.lua;src/?/init.lua;\"..package.path; local db=require(\"luadb\").open({driver=\"local\", storage_path=\"%s\"}); os.execute(\"sleep 0.4\"); db:close()' &", db_file)
os.execute(bg_cmd2)
-- Sleep 0.1s to ensure background process has acquired lock
os.execute("sleep 0.1")

-- Open with busy_timeout = 1500ms (should wait and succeed)
local db4 = luadb.open({ driver = "local", storage_path = db_file, busy_timeout = 1500 })
assert(db4 ~= nil, "Expected db4 to open successfully with busy_timeout")
local r4 = db4:exec("SELECT count(*) AS cnt FROM test_lock;")
assert(#r4 == 1 and r4[1].cnt == 1, "Expected data integrity with busy_timeout")
print("  ✓ [OK] busy_timeout gracefully waited and acquired lock once released")
db4:close()

os.remove(db_file)
os.remove(db_file .. ".wal")
os.remove(db_file .. ".lock")

print("\n[PASS] Multi-Process & Connection File Locking Suite Passed 100%!\n")
