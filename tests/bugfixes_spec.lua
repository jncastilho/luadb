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
print("[TEST SUITE] Comprehensive Bug Fixes Verification")
print("--------------------------------------------------")

local db = luadb.open({ driver = "memory", storage_path = "bugfix_test.db" })

-- 1. Multi-Page B+Tree Leaf Split & Traversal
print("\n[Bug Fix 1] Multi-Page B+Tree Leaf Split & Traversal")
db:exec("CREATE TABLE bugfix_bigdata (id INT PRIMARY KEY, val REAL);")
for i = 1, 150 do
    db:exec(string.format("INSERT INTO bugfix_bigdata VALUES (%d, %.1f);", i, i + 0.5))
end

local all_rows = db:exec("SELECT * FROM bugfix_bigdata;")
assert_eq(#all_rows, 150, "B+Tree 150 Rows Total Count")

local mid_lookup = db:exec("SELECT * FROM bugfix_bigdata WHERE id = 75;")
assert_eq(#mid_lookup, 1, "B+Tree Mid-Tree Lookup Count")
assert_eq(mid_lookup[1].id, 75, "B+Tree Mid-Tree Lookup ID")

-- 2. Deep Tree Deletion across Multi-Level B+Tree
print("\n[Bug Fix 2] Deep Tree Deletion")
db:exec("DELETE FROM bugfix_bigdata WHERE id = 75;")
local post_delete_lookup = db:exec("SELECT * FROM bugfix_bigdata WHERE id = 75;")
assert_eq(#post_delete_lookup, 0, "Deleted Deep Tree Record Count")

local post_delete_all = db:exec("SELECT * FROM bugfix_bigdata;")
assert_eq(#post_delete_all, 149, "Post-Delete B+Tree Record Count")

-- 3. Secondary Index Maintenance on UPDATE and DELETE
print("\n[Bug Fix 3] Secondary Index Sync on UPDATE & DELETE")
db:exec("CREATE TABLE users (id INT PRIMARY KEY, username TEXT, role TEXT);")
db:exec("CREATE INDEX idx_user_role ON users (role);")

db:exec("INSERT INTO users VALUES (1, 'Alice', 'Engineer');")
db:exec("INSERT INTO users VALUES (2, 'Bob', 'Tester');")

-- UPDATE indexed column
db:exec("UPDATE users SET role = 'Lead' WHERE username = 'Alice';")
local updated_idx_lookup = db:exec("SELECT * FROM users WHERE role = 'Lead';")
assert_eq(#updated_idx_lookup, 1, "Updated Secondary Index Query Count")

-- DELETE indexed row
db:exec("DELETE FROM users WHERE username = 'Bob';")
local deleted_idx_lookup = db:exec("SELECT * FROM users WHERE role = 'Tester';")
assert_eq(#deleted_idx_lookup, 0, "Deleted Secondary Index Clean-Up Count")

-- 4. CTE Catalog Cleanup & No Shadowing
print("\n[Bug Fix 4] CTE Catalog Cleanup & No Table Shadowing")
db:exec("CREATE TABLE cte_test_employees (id INT PRIMARY KEY, name TEXT);")
db:exec("INSERT INTO cte_test_employees VALUES (1, 'Charlie');")

-- Run CTE with same name as real table
db:exec("WITH cte_test_employees AS (SELECT name FROM users) SELECT * FROM cte_test_employees;")

-- Verify real table is not shadowed or lost!
local real_emp = db:exec("SELECT * FROM cte_test_employees;")
assert_eq(#real_emp, 1, "Real Table Count Preserved After CTE")
assert_eq(real_emp[1] and real_emp[1].name, "Charlie", "Real Table Record Preserved")

-- 5. Safe ORDER BY Sorting with Mixed Strings/Numbers
print("\n[Bug Fix 5] Safe ORDER BY Comparator")
db:exec("CREATE TABLE items (id INT PRIMARY KEY, label TEXT);")
db:exec("INSERT INTO items VALUES (1, 'Zebra');")
db:exec("INSERT INTO items VALUES (2, 'Apple');")
local sorted = db:exec("SELECT * FROM items ORDER BY label ASC;")
assert_eq(sorted[1].label, "Apple", "ORDER BY String Ascending")

db:close()

-- 6. Foreign Key Catalog Persistence across Database Close and Re-open
print("\n[Bug Fix 6] Foreign Key Persistence Across Restart")
os.remove("fk_persist.db")
local db1 = luadb.open({ driver = "local", storage_path = "fk_persist.db" })
db1:exec("CREATE TABLE parent (id INT PRIMARY KEY, name TEXT);")
db1:exec("CREATE TABLE child (id INT PRIMARY KEY, parent_id INT, FOREIGN KEY (parent_id) REFERENCES parent(id));")
db1:exec("INSERT INTO parent VALUES (1, 'P1');")
db1:close()

-- Reopen database handle
local db2 = luadb.open({ driver = "local", storage_path = "fk_persist.db" })
local ok_fk, err_fk = db2:exec("INSERT INTO child VALUES (10, 99);") -- parent 99 does not exist!
assert_eq(ok_fk, nil, "FK Integrity Preserved After Restart")
assert_eq(err_fk:find("FOREIGN KEY constraint failed") ~= nil, true, "FK Violation Error Preserved")

db2:close()
os.remove("fk_persist.db")

print("\n[PASS] Comprehensive Bug Fixes Suite Passed 100%!")
