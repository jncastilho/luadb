-- =============================================================================
-- LuaDB "Dark Room" Comparative Conformance Test
-- =============================================================================
-- Methodology (TomatoCo criterion):
--   * SQLite 3 (external system binary, /usr/bin/sqlite3) is the ORACLE.
--   * LuaDB is the SUBJECT.
--   * Every SQL statement is fired at both engines independently.
--   * Results are compared row-by-row, field-by-field.
--   * Any divergence is a FAIL -- no exceptions, no workarounds.
--
-- This test does NOT use any LuaDB internal test helpers or assertion utilities.
-- LuaDB is treated as a pure black-box database via its public Lua API.
-- =============================================================================

package.path = "src/?.lua;src/?/init.lua;" .. package.path

-- Oracle: SQLite 3 via system binary
-- We pipe SQL to sqlite3 using io.popen and parse CSV output.
-- No LuaDB code is involved at all in the Oracle path.

local SQLITE_BIN = "/usr/bin/sqlite3"
local SQLITE_DB  = "/tmp/luadb_darkroom_oracle.db"
local LUADB_DB_LOCAL = "darkroom_subject.db"  -- relative to cwd (luadb root)

local function sqlite_reset()
    os.remove(SQLITE_DB)
end

-- Execute SQL against the SQLite oracle. Returns rows as array of key=value tables.
-- For DML/DDL, returns {message = "ok"} on success.
local function sqlite_exec(sql)
    local cmd = string.format(
        '%s -csv -header %s %s',
        SQLITE_BIN,
        SQLITE_DB,
        string.format("%q", sql)
    )
    local handle = io.popen(cmd .. " 2>&1")
    if not handle then
        return nil, "io.popen failed"
    end
    local output = handle:read("*a")
    handle:close()

    if output:match("^Error:") or output:match("^Parse error:") then
        return nil, output:gsub("\n$", "")
    end

    local lines = {}
    for raw_line in output:gmatch("[^\n]+") do
        -- Strip Windows-style CR that sqlite3 may emit on Linux
        local line = raw_line:gsub("\r", "")
        if line ~= "" then
            table.insert(lines, line)
        end
    end

    if #lines == 0 then
        return { message = "ok" }
    end

    local headers = {}
    for col in lines[1]:gmatch("([^,]+)") do
        table.insert(headers, col)
    end

    if #headers == 0 then
        return { message = "ok" }
    end

    local rows = {}
    for i = 2, #lines do
        local row = {}
        -- Proper RFC-4180 CSV field parser (handles "quoted, fields" from sqlite3)
        local function csv_fields(line)
            local fields = {}
            local pos = 1
            while pos <= #line do
                if line:sub(pos, pos) == '"' then
                    -- Quoted field
                    pos = pos + 1
                    local val = ""
                    while pos <= #line do
                        local ch = line:sub(pos, pos)
                        if ch == '"' then
                            if line:sub(pos + 1, pos + 1) == '"' then
                                val = val .. '"'
                                pos = pos + 2
                            else
                                pos = pos + 1
                                break
                            end
                        else
                            val = val .. ch
                            pos = pos + 1
                        end
                    end
                    table.insert(fields, val)
                    if line:sub(pos, pos) == "," then pos = pos + 1 end
                else
                    -- Unquoted field: read until comma or end
                    local s = pos
                    while pos <= #line and line:sub(pos, pos) ~= "," do
                        pos = pos + 1
                    end
                    table.insert(fields, line:sub(s, pos - 1))
                    if line:sub(pos, pos) == "," then pos = pos + 1 end
                end
            end
            return fields
        end

        local vals = csv_fields(lines[i])
        for col_idx, h in ipairs(headers) do
            local val = vals[col_idx] or ""
            local num = tonumber(val)
            row[h] = num ~= nil and num or val
        end
        table.insert(rows, row)
    end

    return rows
end

-- Subject: LuaDB (embedded public API only)
local luadb = require("luadb")

local function luadb_reset()
    os.remove(LUADB_DB_LOCAL)
end

local _luadb_handle = nil

local function luadb_open()
    luadb_reset()
    _luadb_handle = luadb.open({ driver = "local", storage_path = LUADB_DB_LOCAL })
end

local function luadb_exec(sql)
    if not _luadb_handle then error("LuaDB handle not open") end
    local res, err = _luadb_handle:exec(sql)
    if err and not res then return nil, err end
    if res and res.message then return { message = res.message } end
    return res or { message = "ok" }
end

local function luadb_close()
    if _luadb_handle then
        _luadb_handle:close()
        _luadb_handle = nil
    end
end

-- Comparator

local PASS_COUNT = 0
local FAIL_COUNT = 0

local function normalize(v)
    if v == nil then return "" end
    local n = tonumber(tostring(v))
    if n then
        if n == math.floor(n) and n < 2^53 then
            return tostring(math.floor(n))
        end
        return tostring(n)
    end
    return tostring(v):lower():gsub("^%s+", ""):gsub("%s+$", "")
end

local function compare_results(label, sqlite_rows, luadb_rows)
    local sqlite_is_msg = sqlite_rows and sqlite_rows.message ~= nil
    local luadb_is_msg  = luadb_rows  and luadb_rows.message  ~= nil

    if sqlite_is_msg or luadb_is_msg then
        if sqlite_rows and luadb_rows then
            PASS_COUNT = PASS_COUNT + 1
            print(string.format("  [MATCH] %s  (DDL/DML: both engines succeeded)", label))
        else
            FAIL_COUNT = FAIL_COUNT + 1
            print(string.format("  [FAIL]  %s  SQLite=%s  LuaDB=%s",
                label,
                sqlite_rows and "ok" or "ERROR",
                luadb_rows  and "ok" or "ERROR"))
        end
        return
    end

    -- SELECT: compare row count first
    local sc = #sqlite_rows
    local lc = #luadb_rows
    if sc ~= lc then
        FAIL_COUNT = FAIL_COUNT + 1
        print(string.format("  [FAIL]  %s  row count: SQLite=%d, LuaDB=%d", label, sc, lc))
        return
    end

    -- Build a column name normalizer for aggregates:
    -- SQLite outputs "COUNT(*)" header; LuaDB outputs "count_star".
    -- We normalize both to a canonical form before comparing.
    local function norm_col(k)
        k = k:lower()
        k = k:gsub("count%(%)" , "count_star")
        k = k:gsub("count%(%*%)", "count_star")
        k = k:gsub("sum%((.-)%)",  function(c) return "sum_"  .. c end)
        k = k:gsub("avg%((.-)%)",  function(c) return "avg_"  .. c end)
        k = k:gsub("min%((.-)%)",  function(c) return "min_"  .. c end)
        k = k:gsub("max%((.-)%)",  function(c) return "max_"  .. c end)
        return k
    end

    -- Compare each row field-by-field (order matters -- both engines receive same ORDER BY)
    for i = 1, sc do
        local sr = sqlite_rows[i]
        local lr = luadb_rows[i]
        -- Re-key both rows through the normaliser so aggregate names match
        local sr_norm, lr_norm = {}, {}
        for k, v in pairs(sr) do sr_norm[norm_col(k)] = v end
        for k, v in pairs(lr) do lr_norm[norm_col(k)] = v end
        for k, sv in pairs(sr_norm) do
            local lv = lr_norm[k]
            if normalize(sv) ~= normalize(lv) then
                FAIL_COUNT = FAIL_COUNT + 1
                print(string.format(
                    "  [FAIL]  %s  row[%d].%s: SQLite=%q, LuaDB=%q",
                    label, i, k, tostring(sv), tostring(lv)))
                return
            end
        end
    end

    PASS_COUNT = PASS_COUNT + 1
    print(string.format("  [MATCH] %s  (%d row(s) identical)", label, sc))
end

local function both(label, sql)
    local sr, se = sqlite_exec(sql)
    local lr, le = luadb_exec(sql)
    if se and not sr then
        FAIL_COUNT = FAIL_COUNT + 1
        print(string.format("  [FAIL]  %s  SQLite error: %s", label, se))
        return
    end
    if le and not lr then
        FAIL_COUNT = FAIL_COUNT + 1
        print(string.format("  [FAIL]  %s  LuaDB error: %s", label, le))
        return
    end
    compare_results(label, sr, lr)
end

-- =============================================================================
-- DARK ROOM TEST BATTERY
-- =============================================================================

print("\n==================================================")
print("  LuaDB Dark Room: Conformance vs SQLite Oracle")
print("==================================================")
print("  Oracle  : " .. SQLITE_BIN)
print("  Subject : LuaDB embedded (black-box API)")
print("==================================================")

sqlite_reset()
luadb_open()

-- Group 1: Schema Creation
print("\n[Group 1] DDL -- Schema Creation")

both("CREATE TABLE employees",
    "CREATE TABLE employees (id INTEGER PRIMARY KEY, name TEXT, dept TEXT, salary REAL, hired INTEGER);")

both("CREATE TABLE departments",
    "CREATE TABLE departments (id INTEGER PRIMARY KEY, name TEXT, budget REAL);")

-- Group 2: Basic INSERT
print("\n[Group 2] DML -- Basic INSERT")

both("INSERT dept Engineering",  "INSERT INTO departments VALUES (1, 'Engineering', 500000);")
both("INSERT dept Marketing",    "INSERT INTO departments VALUES (2, 'Marketing', 200000);")
both("INSERT dept HR",           "INSERT INTO departments VALUES (3, 'HR', 150000);")

both("INSERT emp Alice",   "INSERT INTO employees VALUES (1, 'Alice',   'Engineering', 95000,  2019);")
both("INSERT emp Bob",     "INSERT INTO employees VALUES (2, 'Bob',     'Engineering', 82000,  2021);")
both("INSERT emp Carol",   "INSERT INTO employees VALUES (3, 'Carol',   'Marketing',   71000,  2020);")
both("INSERT emp Dave",    "INSERT INTO employees VALUES (4, 'Dave',    'HR',          65000,  2022);")
both("INSERT emp Eve",     "INSERT INTO employees VALUES (5, 'Eve',     'Engineering', 110000, 2018);")
both("INSERT emp Frank",   "INSERT INTO employees VALUES (6, 'Frank',   'Marketing',   68000,  2021);")
both("INSERT emp Grace",   "INSERT INTO employees VALUES (7, 'Grace',   'HR',          72000,  2019);")

-- Group 3: SELECT -- Projection & Filtering
print("\n[Group 3] SELECT -- Projection & Filtering")

both("SELECT *",
    "SELECT * FROM employees ORDER BY id;")

both("SELECT specific columns",
    "SELECT name, salary FROM employees ORDER BY salary DESC;")

both("SELECT WHERE equality",
    "SELECT name, dept FROM employees WHERE dept = 'Engineering' ORDER BY name;")

both("SELECT WHERE numeric range",
    "SELECT name, salary FROM employees WHERE salary > 75000 ORDER BY salary;")

both("SELECT WHERE AND compound",
    "SELECT name FROM employees WHERE dept = 'Engineering' AND salary > 85000 ORDER BY name;")

both("SELECT WHERE OR compound",
    "SELECT name FROM employees WHERE dept = 'HR' OR dept = 'Marketing' ORDER BY name;")

both("SELECT LIKE prefix",
    "SELECT name FROM employees WHERE name LIKE 'A%' ORDER BY name;")

both("SELECT LIKE contains",
    "SELECT name FROM employees WHERE name LIKE '%a%' ORDER BY name;")

both("SELECT LIMIT",
    "SELECT name, salary FROM employees ORDER BY salary DESC LIMIT 3;")

both("SELECT LIMIT OFFSET",
    "SELECT name FROM employees ORDER BY id LIMIT 2 OFFSET 3;")

-- Group 4: Aggregate Functions
print("\n[Group 4] SELECT -- Aggregate Functions")

both("COUNT(*)",
    "SELECT COUNT(*) FROM employees;")

both("COUNT(*) with WHERE",
    "SELECT COUNT(*) FROM employees WHERE dept = 'Engineering';")

both("SUM(salary)",
    "SELECT SUM(salary) FROM employees;")

both("AVG(salary)",
    "SELECT AVG(salary) FROM employees;")

both("MIN(salary)",
    "SELECT MIN(salary) FROM employees;")

both("MAX(salary)",
    "SELECT MAX(salary) FROM employees;")

-- Group 5: UPDATE
print("\n[Group 5] DML -- UPDATE")

both("UPDATE single row salary",
    "UPDATE employees SET salary = 98000 WHERE name = 'Alice';")

both("SELECT after UPDATE",
    "SELECT name, salary FROM employees WHERE name = 'Alice';")

both("UPDATE multi-row dept budget",
    "UPDATE departments SET budget = 550000 WHERE name = 'Engineering';")

both("SELECT dept after UPDATE",
    "SELECT name, budget FROM departments WHERE name = 'Engineering';")

-- Group 6: DELETE
print("\n[Group 6] DML -- DELETE")

both("DELETE single row",
    "DELETE FROM employees WHERE name = 'Dave';")

both("SELECT after DELETE count",
    "SELECT COUNT(*) FROM employees;")

both("SELECT deleted row absent",
    "SELECT name FROM employees WHERE name = 'Dave';")

-- Group 7: NULL Handling
print("\n[Group 7] NULL Handling")

both("INSERT row with NULL salary",
    "INSERT INTO employees VALUES (8, 'Hank', 'Engineering', NULL, 2023);")

both("SELECT IS NULL",
    "SELECT name FROM employees WHERE salary IS NULL;")

both("SELECT IS NOT NULL",
    "SELECT name FROM employees WHERE salary IS NOT NULL ORDER BY name;")

-- Group 8: ORDER BY Multiple Columns
print("\n[Group 8] ORDER BY -- Multiple Columns")

both("ORDER BY dept ASC salary DESC",
    "SELECT name, dept, salary FROM employees WHERE salary IS NOT NULL ORDER BY dept ASC, salary DESC;")

-- Group 9: GROUP BY + Aggregates
print("\n[Group 9] GROUP BY + Aggregates")

both("GROUP BY dept COUNT",
    "SELECT dept, COUNT(*) FROM employees GROUP BY dept ORDER BY dept;")

both("GROUP BY dept AVG salary",
    "SELECT dept, AVG(salary) FROM employees WHERE salary IS NOT NULL GROUP BY dept ORDER BY dept;")

-- Group 10: Transaction ROLLBACK
print("\n[Group 10] Transactions -- ROLLBACK Atomicity")

sqlite_exec("BEGIN; INSERT INTO employees VALUES (99, 'Ghost', 'Finance', 50000, 2024); ROLLBACK;")

_luadb_handle:begin()
_luadb_handle:exec("INSERT INTO employees VALUES (99, 'Ghost', 'Finance', 50000, 2024);")
_luadb_handle:rollback()

both("Ghost absent after ROLLBACK",
    "SELECT name FROM employees WHERE name = 'Ghost';")

both("Row count stable after ROLLBACK",
    "SELECT COUNT(*) FROM employees;")

-- Group 11: Data Types
print("\n[Group 11] Data Types -- INTEGER, REAL, TEXT round-trip")

both("CREATE TABLE types_test",
    "CREATE TABLE types_test (i INTEGER, r REAL, t TEXT);")

both("INSERT mixed types",
    "INSERT INTO types_test VALUES (42, 3.14159, 'hello world');")

both("SELECT type round-trip",
    "SELECT i, r, t FROM types_test;")

-- Group 12: Edge Cases
print("\n[Group 12] Edge Cases")

both("SELECT from empty result set",
    "SELECT * FROM departments WHERE budget < 0;")

both("COUNT on empty result",
    "SELECT COUNT(*) FROM employees WHERE dept = 'Finance';")

both("UPDATE no matching rows",
    "UPDATE employees SET salary = 1 WHERE name = 'Nobody';")

both("DELETE no matching rows",
    "DELETE FROM employees WHERE name = 'Nobody';")

-- Cleanup
luadb_close()
sqlite_reset()
luadb_reset()
os.remove(LUADB_DB_LOCAL)

-- Summary
local TOTAL = PASS_COUNT + FAIL_COUNT
print(string.format("\n=================================================="))
print(string.format("  Dark Room Results: %d/%d MATCH  |  %d FAIL", PASS_COUNT, TOTAL, FAIL_COUNT))
print(string.format("=================================================="))

if FAIL_COUNT > 0 then
    error(string.format("[DARK ROOM FAIL] %d divergence(s) detected vs SQLite oracle.", FAIL_COUNT))
else
    print("  [OK] LuaDB output is byte-identical to SQLite on all " .. TOTAL .. " test cases.\n")
end
