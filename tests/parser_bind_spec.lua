package.path = "src/?.lua;src/?/init.lua;" .. package.path

local luadb = require("luadb")

print("\n--------------------------------------------------")
print("[TEST SUITE] SQL Parser Strict Parameter Binding Suite")
print("--------------------------------------------------")

local db_file = "bind_test.db"
os.remove(db_file)
os.remove(db_file .. ".wal")
os.remove(db_file .. ".lock")

local db = luadb.open({ driver = "local", storage_path = db_file })
db:exec("CREATE TABLE users (id INT PRIMARY KEY, name TEXT, age INT);")
db:exec("INSERT INTO users VALUES (1, 'Alice', 30);")
db:exec("INSERT INTO users VALUES (2, 'Bob', 25);")

-- 1. Query with correct parameters
local rows, err = db:exec("SELECT name FROM users WHERE id = ?;", { 1 })
assert(rows and #rows == 1, "Expected 1 row for bound parameter")
assert(rows[1].name == "Alice", "Expected name 'Alice', got " .. tostring(rows[1].name))
print("  ✓ [OK] Correct parameter binding resolved successfully")

-- 2. Query with multiple parameters
local rows2, err2 = db:exec("SELECT name FROM users WHERE age > ? AND age < ?;", { 20, 28 })
assert(rows2 and #rows2 == 1, "Expected 1 row for multiple bounds")
assert(rows2[1].name == "Bob", "Expected name 'Bob', got " .. tostring(rows2[1].name))
print("  ✓ [OK] Multiple parameter bindings resolved correctly")

-- 3. Query with missing parameter must FAIL with strict error (not inject 'luadb')
local fail_res, fail_err = db:exec("SELECT * FROM users WHERE id = ?;")
assert(fail_res == nil, "Expected query to fail when parameter is missing")
assert(fail_err and fail_err:find("Bind error"), "Expected 'Bind error' message, got: " .. tostring(fail_err))
print("  ✓ [OK] Missing single parameter strictly rejected: " .. fail_err)

-- 4. Query with partially missing parameters must FAIL
local fail_res2, fail_err2 = db:exec("SELECT * FROM users WHERE id = ? AND age = ?;", { 1 })
assert(fail_res2 == nil, "Expected query to fail when second parameter is missing")
assert(fail_err2 and fail_err2:find("Bind error"), "Expected 'Bind error' for 2nd param, got: " .. tostring(fail_err2))
print("  ✓ [OK] Partially missing parameter strictly rejected: " .. fail_err2)

db:close()
os.remove(db_file)
os.remove(db_file .. ".wal")
os.remove(db_file .. ".lock")

print("\n[PASS] SQL Parser Strict Parameter Binding Suite Passed 100%!\n")
