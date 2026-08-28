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
print("[TEST SUITE] Advanced RDBMS Features (ALTER, CASCADE, CTE)")
print("--------------------------------------------------")

local db = luadb.open({ driver = "memory", storage_path = "adv_test.db" })

-- 1. ALTER TABLE ADD COLUMN
print("\n[Adv Test 1] ALTER TABLE ADD COLUMN")
db:exec("CREATE TABLE users (id INT PRIMARY KEY, name TEXT);")
db:exec("INSERT INTO users VALUES (1, 'Alice');")

local res_add = db:exec("ALTER TABLE users ADD COLUMN age INT;")
assert_eq(res_add.message, "Table users column age added successfully", "ADD COLUMN Execution Message")

-- 2. ALTER TABLE RENAME TO
print("\n[Adv Test 2] ALTER TABLE RENAME TO")
local res_rename = db:exec("ALTER TABLE users RENAME TO accounts;")
assert_eq(res_rename.message, "Table users renamed to accounts", "RENAME TO Execution Message")

local renamed_rows = db:exec("SELECT * FROM accounts WHERE id = 1;")
assert_eq(#renamed_rows, 1, "Renamed Table Row Query")
assert_eq(renamed_rows[1].name, "Alice", "Renamed Table Field Value")

-- 3. FOREIGN KEY ON DELETE CASCADE
print("\n[Adv Test 3] FOREIGN KEY ON DELETE CASCADE")
db:exec("CREATE TABLE parent_orgs (id INT PRIMARY KEY, name TEXT);")
db:exec("CREATE TABLE child_members (id INT PRIMARY KEY, name TEXT, org_id INT, FOREIGN KEY (org_id) REFERENCES parent_orgs(id) ON DELETE CASCADE);")

db:exec("INSERT INTO parent_orgs VALUES (10, 'Cloud Org');")
db:exec("INSERT INTO child_members VALUES (101, 'Member A', 10);")
db:exec("INSERT INTO child_members VALUES (102, 'Member B', 10);")

-- Delete parent row -> should automatically cascade delete child rows!
db:exec("DELETE FROM parent_orgs WHERE id = 10;")
local remaining_children = db:exec("SELECT * FROM child_members WHERE org_id = 10;")
assert_eq(#remaining_children, 0, "Cascaded Child Row Deletion Count")

-- 4. WITH CTE (Common Table Expressions)
print("\n[Adv Test 4] WITH CTE (Common Table Expression)")
db:exec("CREATE TABLE staff (id INT PRIMARY KEY, name TEXT, dept TEXT);")
db:exec("INSERT INTO staff VALUES (1, 'Charlie', 'Engineering');")
db:exec("INSERT INTO staff VALUES (2, 'Dave', 'Sales');")

local cte_rows = db:exec("WITH engineers AS (SELECT name, dept FROM staff WHERE dept = 'Engineering') SELECT * FROM engineers;")
assert_eq(#cte_rows, 1, "CTE Query Result Count")

db:close()

print("\n[PASS] Advanced RDBMS Features Suite Passed 100%!")
