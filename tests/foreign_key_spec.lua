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
print("[TEST SUITE] Foreign Keys & Referential Integrity")
print("--------------------------------------------------")

local db = luadb.open({ driver = "memory", storage_path = "fk_test.db" })

-- 1. Create Parent and Child Tables with Foreign Key
print("\n[FK Test 1] CREATE TABLE with FOREIGN KEY Constraint")
db:exec("CREATE TABLE depts (id INT PRIMARY KEY, dname TEXT);")
local res_child = db:exec("CREATE TABLE emps (id INT PRIMARY KEY, name TEXT, dept_id INT, FOREIGN KEY (dept_id) REFERENCES depts(id));")
assert_eq(res_child.message, "Table created: emps", "Foreign Key Table Creation")

-- 2. Valid Insert into Parent and Child
print("\n[FK Test 2] Valid Parent & Child Ingestion")
db:exec("INSERT INTO depts VALUES (1, 'Engineering');")
db:exec("INSERT INTO depts VALUES (2, 'Marketing');")
db:exec("INSERT INTO emps VALUES (101, 'Alice', 1);")
local emp_rows = db:exec("SELECT * FROM emps WHERE name = 'Alice';")
assert_eq(#emp_rows, 1, "Valid FK Child Insert Count")

-- 3. Invalid Child Insert (Non-existent Parent Foreign Key)
print("\n[FK Test 3] Invalid Child Insert Rejection")
local ok_ins, err_ins = db:exec("INSERT INTO emps VALUES (102, 'Bob', 99);")
assert_eq(ok_ins, nil, "Rejected Non-Existent FK Parent")
assert_eq(err_ins:find("FOREIGN KEY constraint failed") ~= nil, true, "FK Violation Error Message")

-- 4. Invalid Parent Delete Protection (Child Records Depend On It)
print("\n[FK Test 4] Invalid Parent Delete Protection")
local ok_del, err_del = db:exec("DELETE FROM depts WHERE id = 1;")
assert_eq(ok_del, nil, "Protected Parent Row Deletion")
assert_eq(err_del:find("FOREIGN KEY constraint failed") ~= nil, true, "FK Delete Protection Error Message")

-- 5. Valid Delete After Child Clean-Up
print("\n[FK Test 5] Valid Parent Delete Post Child Clean-Up")
db:exec("DELETE FROM emps WHERE id = 101;")
local res_del_parent = db:exec("DELETE FROM depts WHERE id = 1;")
assert_eq(res_del_parent.message, "Deleted 1 rows", "Valid Parent Row Deletion")

db:close()

print("\n[PASS] Foreign Keys & Referential Integrity Suite Passed 100%!")
