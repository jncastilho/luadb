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
print("[TEST SUITE] Crash Recovery & WAL Integrity Fuzzing")
print("--------------------------------------------------")

os.remove("crash_test.db")

-- 1. Ingest Initial Stable Data
print("\n[Crash Recovery Test 1] Ingest Baseline Committed Data")
local db = luadb.open({ driver = "local", storage_path = "crash_test.db" })
db:exec("CREATE TABLE accounts (id INT PRIMARY KEY, owner TEXT, balance REAL);")
db:exec("INSERT INTO accounts VALUES (1, 'Alice', 1000.0);")
db:exec("INSERT INTO accounts VALUES (2, 'Bob', 500.0);")
db:close()

-- 2. Simulate Mid-Transaction Process Interruption (Uncommitted dirty page state)
print("\n[Crash Recovery Test 2] Simulate Uncommitted Dirty Transaction Interruption")
local db2 = luadb.open({ driver = "local", storage_path = "crash_test.db" })
db2:begin()
db2:exec("UPDATE accounts SET balance = 0.0 WHERE id = 1;")
db2:exec("INSERT INTO accounts VALUES (3, 'Malicious Uncommitted', 99999.0);")

-- Simulate sudden crash/kill WITHOUT calling db2:commit() or db2:close()
-- We call WAL recover directly to simulate process restart recovery
db2.wal:recover()

-- 3. Verify Database Storage Remains Clean & Uncorrupted
print("\n[Crash Recovery Test 3] Verify Post-Crash Storage Integrity")
local db3 = luadb.open({ driver = "local", storage_path = "crash_test.db" })
local rows = db3:exec("SELECT * FROM accounts ORDER BY id ASC;")

assert_eq(#rows, 2, "Post-Crash Record Count (Uncommitted Mutations Reverted)")
assert_eq(rows[1].owner, "Alice", "Row 1 Owner Intact")
assert_eq(rows[1].balance, 1000.0, "Row 1 Balance Intact (Not Zeroed)")
assert_eq(rows[2].owner, "Bob", "Row 2 Owner Intact")

db3:close()
os.remove("crash_test.db")

print("\n[PASS] Crash Recovery & WAL Integrity Suite Passed 100%!")
