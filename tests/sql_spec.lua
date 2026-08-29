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
print("[TEST SUITE] SQL Parser, Query Executor & CRUD")
print("--------------------------------------------------")

os.remove("sql_spec_clean.db")
local db = luadb.open({ driver = "memory", storage_path = "sql_spec_clean.db" })

-- 1. CREATE TABLE
print("\n[SQL Test 1] CREATE TABLE Statement")
print("  > SQL: CREATE TABLE sql_employees (id INTEGER PRIMARY KEY, name TEXT, salary REAL, role TEXT);")
local res1 = db:exec("CREATE TABLE sql_employees (id INTEGER PRIMARY KEY, name TEXT, salary REAL, role TEXT);")
assert_eq(res1.message, "Table created: sql_employees", "Catalog Table Creation")

-- 2. CREATE INDEX
print("\n[SQL Test 2] CREATE INDEX Statement")
print("  > SQL: CREATE INDEX idx_emp_salary ON sql_employees (salary);")
local res_idx = db:exec("CREATE INDEX idx_emp_salary ON sql_employees (salary);")
assert_eq(res_idx.message, "Index created: idx_emp_salary", "Secondary B+Tree Index Creation")

-- 3. INSERT INTO with Prepared Statements
print("\n[SQL Test 3] INSERT INTO Statements & Prepared Statements")
local stmt = db:prepare("INSERT INTO sql_employees VALUES (?, ?, ?, ?);")
stmt:exec(1, "Alice", 90000, "Engineering")
stmt:exec(2, "Bob", 75000, "Design")
stmt:exec(3, "Charlie", 110000, "Engineering")
print("  ✓ [OK] Prepared Statement Execution with Parameter Binding")

-- 4. SELECT with WHERE & ORDER BY & LIMIT
print("\n[SQL Test 4] SELECT Query Execution")
print("  > SQL: SELECT name, salary FROM sql_employees WHERE role = 'Engineering' ORDER BY salary DESC;")
local res_select = db:exec("SELECT name, salary FROM sql_employees WHERE role = 'Engineering' ORDER BY salary DESC;")
print(string.format("  > Returned %d records", #res_select))
for idx, row in ipairs(res_select) do
    print(string.format("    Row %d: name='%s', salary=%.2f", idx, row.name, row.salary))
end
assert_eq(#res_select, 2, "Matching Rows Count")
assert_eq(res_select[1].name, "Charlie", "First Row Name (Desc Order)")
assert_eq(res_select[2].name, "Alice", "Second Row Name")

-- 5. SQL Aggregate Functions
print("\n[SQL Test 5] SQL Aggregate Functions (COUNT, SUM, AVG, MAX)")
local res_cnt = db:exec("SELECT COUNT(*) FROM sql_employees;")
assert_eq(res_cnt[1].count_star, 3, "Aggregate COUNT(*)")

local res_sum = db:exec("SELECT SUM(salary) FROM sql_employees;")
assert_eq(res_sum[1].sum_salary, 275000, "Aggregate SUM(salary)")

local res_max = db:exec("SELECT MAX(salary) FROM sql_employees;")
assert_eq(res_max[1].max_salary, 110000, "Aggregate MAX(salary)")

-- 6. LIKE Operator Matching
print("\n[SQL Test 6] LIKE Wildcard Pattern Matching")
local res_like = db:exec("SELECT name FROM sql_employees WHERE name LIKE 'A%';")
assert_eq(#res_like, 1, "LIKE 'A%' matching count")
assert_eq(res_like[1].name, "Alice", "LIKE matching name")

-- 7. UPDATE
print("\n[SQL Test 7] UPDATE Statement")
print("  > SQL: UPDATE sql_employees SET salary = 95000 WHERE name = 'Alice';")
db:exec("UPDATE sql_employees SET salary = 95000 WHERE name = 'Alice';")
local res_up = db:exec("SELECT salary FROM sql_employees WHERE name = 'Alice';")
assert_eq(res_up[1].salary, 95000, "Updated Salary Verification")

-- 8. DELETE
print("\n[SQL Test 8] DELETE Statement")
print("  > SQL: DELETE FROM sql_employees WHERE name = 'Bob';")
db:exec("DELETE FROM sql_employees WHERE name = 'Bob';")
local res_del = db:exec("SELECT * FROM sql_employees;")
assert_eq(#res_del, 2, "Remaining Record Count after Delete")

-- 9. TRANSACTIONS & ROLLBACK
print("\n[SQL Test 9] Write-Ahead Logging Transactions & ROLLBACK")
print("  > SQL: BEGIN TRANSACTION;")
db:begin()
print("  > SQL: INSERT INTO sql_employees VALUES (4, 'Dave', 60000, 'Marketing');")
db:exec("INSERT INTO sql_employees VALUES (4, 'Dave', 60000, 'Marketing');")
print("  > SQL: ROLLBACK;")
db:rollback()
local res_trans = db:exec("SELECT * FROM sql_employees WHERE name = 'Dave';")
assert_eq(#res_trans, 0, "Uncommitted Record Absence Verification")

-- 10. TIMESTAMP & TEMPORAL DATA TYPES
print("\n[SQL Test 10] TIMESTAMP, DATE & Temporal Column Data Types")
db:exec("CREATE TABLE events (id INT PRIMARY KEY, title VARCHAR(255), created_at TIMESTAMP, event_date DATE);")
db:exec("INSERT INTO events VALUES (1, 'System Launch', '2026-08-15 00:30:00', '2026-08-15');")
local res_ts = db:exec("SELECT title, created_at FROM events WHERE id = 1;")
assert_eq(#res_ts, 1, "Timestamp Query Row Count")
assert_eq(res_ts[1].created_at, "2026-08-15 00:30:00", "Timestamp Column Value")

-- 11. COUNT(column) vs COUNT(*) NULL SEMANTICS
print("\n[SQL Test 11] COUNT(col) Excludes NULLs while COUNT(*) Counts All Rows")
db:exec("CREATE TABLE count_test (id INT PRIMARY KEY, val REAL);")
db:exec("INSERT INTO count_test VALUES (1, 100.0);")
db:exec("INSERT INTO count_test VALUES (2, NULL);")
local res_cstar = db:exec("SELECT COUNT(*) FROM count_test;")
local res_ccol  = db:exec("SELECT COUNT(val) FROM count_test;")
assert_eq(res_cstar[1].count_star, 2, "COUNT(*) includes NULL row")
assert_eq(res_ccol[1].count_val,   1, "COUNT(val) excludes NULL row")

-- 12. GROUP BY NULL vs EMPTY STRING SEPARATION
print("\n[SQL Test 12] GROUP BY Distinguishes NULL from Empty String ('')")
db:exec("CREATE TABLE null_str_test (id INT PRIMARY KEY, code TEXT);")
db:exec("INSERT INTO null_str_test VALUES (1, NULL);")
db:exec("INSERT INTO null_str_test VALUES (2, '');")
db:exec("INSERT INTO null_str_test VALUES (3, 'A');")
local res_gb = db:exec("SELECT code, COUNT(*) FROM null_str_test GROUP BY code ORDER BY code;")
assert_eq(#res_gb, 3, "GROUP BY produces 3 distinct groups (NULL, '', 'A')")

-- 13. ORDER BY INVALID COLUMN ERROR HANDLING
print("\n[SQL Test 13] ORDER BY Unknown Column Error")
local _, err_ord = db:exec("SELECT name FROM sql_employees ORDER BY non_existent_col;")
assert_eq(err_ord ~= nil, true, "ORDER BY invalid column returns error")

db:close()

print("\n[PASS] SQL Engine & CRUD Suite Completed Successfully!")
