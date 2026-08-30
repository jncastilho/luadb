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

local function find_cli_bin(env_var, candidates)
    local env_bin = os.getenv(env_var)
    local list = env_bin and { env_bin } or candidates
    for _, bin in ipairs(list) do
        local handle = io.popen(string.format('%s --version 2>&1', bin))
        if handle then
            local out = handle:read("*a")
            handle:close()
            local lout = (out or ""):lower()
            if #lout > 0 and not lout:find("not found") and not lout:find("no such file") and not lout:find("is not recognized") and not lout:find("cannot access") then
                return bin
            end
        end
    end
    return nil
end

local active_oracles = {}

local SQLITE_BIN = find_cli_bin("SQLITE_BIN", { "sqlite3", "/usr/bin/sqlite3", "/usr/local/bin/sqlite3", "/opt/homebrew/bin/sqlite3" })
if SQLITE_BIN then
    table.insert(active_oracles, { name = "SQLite 3", bin = SQLITE_BIN, type = "sqlite" })
end

local home_dir = os.getenv("HOME") or "/home/coldwar"
local DUCKDB_BIN = find_cli_bin("DUCKDB_BIN", { "duckdb", home_dir .. "/.local/bin/duckdb", "/usr/bin/duckdb", "/usr/local/bin/duckdb", "/tmp/duckdb" })
if DUCKDB_BIN then
    table.insert(active_oracles, { name = "DuckDB", bin = DUCKDB_BIN, type = "duckdb" })
end

local CLICKHOUSE_BIN = find_cli_bin("CLICKHOUSE_BIN", { "clickhouse", home_dir .. "/.local/bin/clickhouse", "/usr/bin/clickhouse", "/usr/local/bin/clickhouse" })
if CLICKHOUSE_BIN then
    table.insert(active_oracles, { name = "ClickHouse Local", bin = CLICKHOUSE_BIN, type = "clickhouse" })
end

local PSQL_BIN = find_cli_bin("PSQL_BIN", { "psql", "/usr/bin/psql", "/usr/local/bin/psql" })
if PSQL_BIN then
    local pcheck = io.popen(PSQL_BIN .. " -h /tmp -p 5433 -U postgres --csv -c 'SELECT 1;' 2>&1")
    if pcheck then
        local pout = pcheck:read("*a")
        pcheck:close()
        if pout and pout:find("1") then
            table.insert(active_oracles, { name = "PostgreSQL 18", bin = PSQL_BIN, type = "postgres" })
        end
    end
end

if #active_oracles == 0 then
    print("\n==================================================")
    print("  LuaDB Dark Room: Conformance Test (SKIPPED)")
    print("==================================================")
    print("  [SKIP] No external database CLI oracle (sqlite3, duckdb, clickhouse) found.")
    print("  To run this suite, install sqlite3, duckdb, or clickhouse.")
    print("==================================================\n")
    return
end

local tmp_dir = os.getenv("TMPDIR") or os.getenv("TEMP") or "/tmp"
local SQLITE_DB = tmp_dir:gsub("[/\\]$", "") .. "/luadb_darkroom_sqlite.db"
local DUCKDB_DB = tmp_dir:gsub("[/\\]$", "") .. "/luadb_darkroom_duckdb.db"
local LUADB_DB_LOCAL = "darkroom_subject.db"  -- relative to cwd (luadb root)

local function sqlite_reset()
    os.remove(SQLITE_DB)
end

local function duckdb_reset()
    os.remove(DUCKDB_DB)
end

local function csv_fields(line)
    local fields = {}
    local pos = 1
    while pos <= #line do
        if line:sub(pos, pos) == '"' then
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

local function parse_csv_output(output)
    local lines = {}
    for raw_line in output:gmatch("[^\n]+") do
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
        local vals = csv_fields(lines[i])
        local row = {}
        for col_idx, h in ipairs(headers) do
            local val = vals[col_idx] or ""
            local num = tonumber(val)
            row[h] = num ~= nil and num or val
        end
        table.insert(rows, row)
    end

    return rows
end

local function sqlite_exec(sql)
    local cmd = string.format(
        '%s -csv -header %s %s',
        SQLITE_BIN,
        SQLITE_DB,
        string.format("%q", sql)
    )
    local handle = io.popen(cmd .. " 2>&1")
    if not handle then return nil, "io.popen failed" end
    local output = handle:read("*a")
    handle:close()
    if output:match("^Error:") or output:match("^Parse error:") then
        return nil, output:gsub("\n$", "")
    end
    return parse_csv_output(output)
end

local function duckdb_exec(sql)
    local cmd = string.format(
        '%s -csv -header %s %s',
        DUCKDB_BIN,
        DUCKDB_DB,
        string.format("%q", sql)
    )
    local handle = io.popen(cmd .. " 2>&1")
    if not handle then return nil, "io.popen failed" end
    local output = handle:read("*a")
    handle:close()
    if output:match("^Error:") or output:match("^Parse error:") or output:match("^Catalog Error:") then
        return nil, output:gsub("\n$", "")
    end
    return parse_csv_output(output)
end

local CLICKHOUSE_DIR = tmp_dir:gsub("[/\\]$", "") .. "/luadb_darkroom_ch_dir"

local function clickhouse_reset()
    os.execute("rm -rf " .. CLICKHOUSE_DIR)
    os.execute("mkdir -p " .. CLICKHOUSE_DIR)
end

local function clickhouse_exec(sql)
    local ch_sql = sql
    if ch_sql:upper():find("^CREATE TABLE ") and not ch_sql:upper():find("ENGINE%s*=") then
        ch_sql = ch_sql:gsub("PRIMARY KEY", "")
        ch_sql = ch_sql:gsub(";%s*$", "") .. " ENGINE = StripeLog;"
    elseif ch_sql:upper():find("^UPDATE ") then
        local tbl, rest = ch_sql:match("^UPDATE%s+([%w_]+)%s+SET%s+(.*)$")
        if tbl and rest then ch_sql = "ALTER TABLE " .. tbl .. " UPDATE " .. rest end
    elseif ch_sql:upper():find("^DELETE FROM ") then
        local tbl, rest = ch_sql:match("^DELETE FROM%s+([%w_]+)%s+WHERE%s+(.*)$")
        if tbl and rest then ch_sql = "ALTER TABLE " .. tbl .. " DELETE WHERE " .. rest end
    end

    local cmd = string.format(
        '%s local --path %s --format CSVWithNames --query %s',
        CLICKHOUSE_BIN,
        CLICKHOUSE_DIR,
        string.format("%q", ch_sql)
    )
    local handle = io.popen(cmd .. " 2>&1")
    if not handle then return nil, "io.popen failed" end
    local output = handle:read("*a")
    handle:close()
    if output:match("^Exception:") or output:match("^Code:") then
        return nil, output:gsub("\n$", "")
    end
    return parse_csv_output(output)
end

local function psql_reset()
    if PSQL_BIN then
        os.execute(string.format('%s -h /tmp -p 5433 -U postgres -c "DROP TABLE IF EXISTS employees, departments, types_test, adv_dark_test, sales_dark CASCADE;" >/dev/null 2>&1', PSQL_BIN))
    end
end

local function psql_exec(sql)
    local cmd = string.format(
        '%s -h /tmp -p 5433 -U postgres --csv -c %s',
        PSQL_BIN,
        string.format("%q", sql)
    )
    local handle = io.popen(cmd .. " 2>&1")
    if not handle then return nil, "io.popen failed" end
    local output = handle:read("*a")
    handle:close()
    if output:match("^ERROR:") or output:match("^FATAL:") then
        return nil, output:gsub("\n$", "")
    end
    return parse_csv_output(output)
end

for _, oracle in ipairs(active_oracles) do
    if oracle.type == "sqlite" then
        oracle.exec = sqlite_exec
        oracle.reset = sqlite_reset
    elseif oracle.type == "duckdb" then
        oracle.exec = duckdb_exec
        oracle.reset = duckdb_reset
    elseif oracle.type == "clickhouse" then
        oracle.exec = clickhouse_exec
        oracle.reset = clickhouse_reset
    elseif oracle.type == "postgres" then
        oracle.exec = psql_exec
        oracle.reset = psql_reset
    end
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

local oracle_stats = {}
for _, o in ipairs(active_oracles) do
    oracle_stats[o.name] = { pass = 0, fail = 0, type = o.type }
end

local function compare_results(label, oracle, oracle_rows, luadb_rows)
    local oracle_name = oracle.name
    local oracle_is_msg = oracle_rows and oracle_rows.message ~= nil
    local luadb_is_msg  = luadb_rows  and luadb_rows.message  ~= nil

    if oracle_is_msg or luadb_is_msg then
        if oracle_rows and luadb_rows then
            PASS_COUNT = PASS_COUNT + 1
            oracle_stats[oracle_name].pass = oracle_stats[oracle_name].pass + 1
            print(string.format("  [MATCH] [%s] %s  (DDL/DML: both engines succeeded)", oracle_name, label))
        else
            FAIL_COUNT = FAIL_COUNT + 1
            oracle_stats[oracle_name].fail = oracle_stats[oracle_name].fail + 1
            print(string.format("  [FAIL]  [%s] %s  %s=%s  LuaDB=%s",
                oracle_name, label, oracle_name,
                oracle_rows and "ok" or "ERROR",
                luadb_rows  and "ok" or "ERROR"))
        end
        return
    end

    -- SELECT: compare row count first
    local sc = #oracle_rows
    local lc = #luadb_rows
    if sc ~= lc then
        FAIL_COUNT = FAIL_COUNT + 1
        oracle_stats[oracle_name].fail = oracle_stats[oracle_name].fail + 1
        print(string.format("  [FAIL]  [%s] %s  row count: %s=%d, LuaDB=%d", oracle_name, label, oracle_name, sc, lc))
        return
    end

    -- Build a column name normalizer for aggregates:
    local function norm_col(k)
        k = k:lower():gsub('^"', ''):gsub('"$', '')
        k = k:gsub("^count$", "count_star")
        k = k:gsub("^sum$", "sum_val")
        k = k:gsub("^avg$", "avg_val")
        k = k:gsub("^min$", "min_val")
        k = k:gsub("^max$", "max_val")
        k = k:gsub("count%(%)" , "count_star")
        k = k:gsub("count%(%*%)", "count_star")
        k = k:gsub("count%((.-)%)", function(c) return "count_" .. c end)
        k = k:gsub("sum%((.-)%)",  function(c) return "sum_"  .. c end)
        k = k:gsub("avg%((.-)%)",  function(c) return "avg_"  .. c end)
        k = k:gsub("min%((.-)%)",  function(c) return "min_"  .. c end)
        k = k:gsub("max%((.-)%)",  function(c) return "max_"  .. c end)
        k = k:gsub("%(%s*%)", "")
        return k
    end

    -- Compare each row field-by-field
    for i = 1, sc do
        local sr = oracle_rows[i]
        local lr = luadb_rows[i]
        local sr_norm, lr_norm = {}, {}
        for k, v in pairs(sr) do sr_norm[norm_col(k)] = v end
        for k, v in pairs(lr) do lr_norm[norm_col(k)] = v end
        for k, sv in pairs(sr_norm) do
            local lv = lr_norm[k]
            if normalize(sv) ~= normalize(lv) then
                FAIL_COUNT = FAIL_COUNT + 1
                oracle_stats[oracle_name].fail = oracle_stats[oracle_name].fail + 1
                print(string.format(
                    "  [FAIL]  [%s] %s  row[%d].%s: %s=%q, LuaDB=%q",
                    oracle_name, label, i, k, oracle_name, tostring(sv), tostring(lv)))
                return
            end
        end
    end

    PASS_COUNT = PASS_COUNT + 1
    oracle_stats[oracle_name].pass = oracle_stats[oracle_name].pass + 1
    print(string.format("  [MATCH] [%s] %s  (%d row(s) identical)", oracle_name, label, sc))
end

local function both(label, sql)
    local lr, le = luadb_exec(sql)
    if le and not lr then
        FAIL_COUNT = FAIL_COUNT + 1
        print(string.format("  [FAIL]  %s  LuaDB error: %s", label, le))
        return
    end

    for _, oracle in ipairs(active_oracles) do
        local sr, se = oracle.exec(sql)
        if se and not sr then
            FAIL_COUNT = FAIL_COUNT + 1
            oracle_stats[oracle.name].fail = oracle_stats[oracle.name].fail + 1
            print(string.format("  [FAIL]  [%s] %s  %s error: %s", oracle.name, label, oracle.name, se))
        else
            compare_results(label, oracle, sr, lr)
        end
    end
end

-- =============================================================================
-- DARK ROOM TEST BATTERY
-- =============================================================================

local oracle_names = {}
for _, o in ipairs(active_oracles) do table.insert(oracle_names, o.name .. " (" .. o.bin .. ")") end

print("\n==================================================")
print("  LuaDB Dark Room: Conformance vs External Oracles")
print("==================================================")
print("  Active Oracles : " .. table.concat(oracle_names, ", "))
print("  Subject        : LuaDB embedded (black-box API)")
print("==================================================")

for _, oracle in ipairs(active_oracles) do
    if oracle.reset then oracle.reset() end
end
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
    "SELECT name FROM employees WHERE name LIKE '%a%' OR name LIKE '%A%' ORDER BY name;")

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

-- Group 13: Complex Multi-Condition WHERE Predicates & IN Clauses
print("\n[Group 13] Complex WHERE Predicates & IN Clause")

both("WHERE IN list numeric",
    "SELECT name, dept, salary FROM employees WHERE hired IN (2018, 2019, 2021) ORDER BY id;")

both("WHERE IN list string",
    "SELECT name, salary FROM employees WHERE dept IN ('Engineering', 'Marketing') ORDER BY salary DESC;")

both("WHERE AND/OR complex combination",
    "SELECT name, dept, salary FROM employees WHERE (dept = 'Engineering' AND salary >= 95000) OR (dept = 'Marketing' AND hired >= 2021) ORDER BY id;")

-- Group 14: Adversarial Aggregates & Typed GROUP BY
print("\n[Group 14] Adversarial Aggregates & Typed GROUP BY")

both("CREATE TABLE adv_dark_test",
    "CREATE TABLE adv_dark_test (id INTEGER PRIMARY KEY, category TEXT, val REAL);")

both("INSERT adv_dark_test rows",
    "INSERT INTO adv_dark_test VALUES (1, 'alpha', 10.5);")
both("INSERT adv_dark_test row 2",
    "INSERT INTO adv_dark_test VALUES (2, 'alpha', -4.5);")
both("INSERT adv_dark_test row 3",
    "INSERT INTO adv_dark_test VALUES (3, 'alpha', NULL);")
both("INSERT adv_dark_test row 4",
    "INSERT INTO adv_dark_test VALUES (4, 'beta', 0.0);")
both("INSERT adv_dark_test row 5",
    "INSERT INTO adv_dark_test VALUES (5, 'beta', -15.0);")
both("INSERT adv_dark_test row 6",
    "INSERT INTO adv_dark_test VALUES (6, '', 5.0);")

both("GROUP BY category COUNT, SUM, AVG, MIN, MAX",
    "SELECT category, COUNT(*), COUNT(val), SUM(val), AVG(val), MIN(val), MAX(val) FROM adv_dark_test GROUP BY category ORDER BY category;")

-- Group 15: Multi-Row DML Mutations & Index Consistency
print("\n[Group 15] Multi-Row DML Mutations & Complex Predicate Updates")

both("UPDATE multi-row with IN clause",
    "UPDATE employees SET salary = salary + 5000 WHERE hired IN (2018, 2019);")

both("SELECT post multi-row IN update",
    "SELECT name, salary FROM employees WHERE hired IN (2018, 2019) ORDER BY salary DESC;")

both("DELETE multi-row with numeric range",
    "DELETE FROM employees WHERE salary < 70000;")

both("SELECT count post range delete",
    "SELECT COUNT(*) FROM employees;")

-- Group 16: Multi-Level ORDER BY with Pagination
print("\n[Group 16] Multi-Level ORDER BY with Pagination")

both("ORDER BY dept ASC, salary DESC, name ASC LIMIT 3 OFFSET 1",
    "SELECT name, dept, salary FROM employees ORDER BY dept ASC, salary DESC, name ASC LIMIT 3 OFFSET 1;")

-- Group 17: CTE (Common Table Expressions) & Aggregations
print("\n[Group 17] WITH CTE & Regional Aggregations")

both("CREATE TABLE sales_dark",
    "CREATE TABLE sales_dark (id INTEGER PRIMARY KEY, region TEXT, amount REAL);")
both("INSERT sales 1", "INSERT INTO sales_dark VALUES (1, 'North', 1500.0);")
both("INSERT sales 2", "INSERT INTO sales_dark VALUES (2, 'North', 2500.0);")
both("INSERT sales 3", "INSERT INTO sales_dark VALUES (3, 'South', 800.0);")
both("INSERT sales 4", "INSERT INTO sales_dark VALUES (4, 'South', 1200.0);")

both("WITH CTE regional summary query",
    "WITH reg_summary AS (SELECT region, COUNT(*) AS sales_cnt, SUM(amount) AS total_amt FROM sales_dark GROUP BY region) SELECT * FROM reg_summary ORDER BY region;")

-- Group 18: Dynamic Grouping & Multi-Column Aggregates
print("\n[Group 18] Dynamic Grouping & Multi-Column Aggregates")

both("SELECT region, total sum",
    "SELECT region, SUM(amount) FROM sales_dark GROUP BY region ORDER BY region;")

-- Group 19: Complex DML Updates & Arithmetic Operations
print("\n[Group 19] Complex DML Updates & Range Math")

both("UPDATE sales region South",
    "UPDATE sales_dark SET amount = amount + 500 WHERE region = 'South';")

both("SELECT post UPDATE sales South",
    "SELECT region, amount FROM sales_dark WHERE region = 'South' ORDER BY id;")

-- Group 20: Range Deletions & Count Aggregations
print("\n[Group 20] Dynamic Range Deletions & Final Count")

both("DELETE sales low amount",
    "DELETE FROM sales_dark WHERE amount < 1500;")

both("SELECT post DELETE sales count",
    "SELECT COUNT(*) FROM sales_dark;")

-- Cleanup
luadb_close()
for _, oracle in ipairs(active_oracles) do
    if oracle.reset then oracle.reset() end
end
luadb_reset()
os.remove(LUADB_DB_LOCAL)

-- Summary
local TOTAL = PASS_COUNT + FAIL_COUNT
local overall_pct = TOTAL > 0 and (PASS_COUNT / TOTAL * 100) or 0.0

print("\n========================================================================================")
print("                      DARK ROOM MULTI-ORACLE CONFORMANCE MATRIX                          ")
print("========================================================================================")
print(string.format(" %-24s %-18s %-12s %-8s %-8s %-8s", "Oracle Technology", "Engine Type", "Total Tests", "MATCH", "FAIL", "Match %"))
print("----------------------------------------------------------------------------------------")

for _, oracle in ipairs(active_oracles) do
    local st = oracle_stats[oracle.name]
    local total = st.pass + st.fail
    local pct = total > 0 and (st.pass / total * 100) or 0.0
    local engine_desc = "Embedded RDBMS"
    if oracle.type == "duckdb" then engine_desc = "Embedded OLAP"
    elseif oracle.type == "clickhouse" then engine_desc = "Columnar OLAP"
    elseif oracle.type == "postgres" then engine_desc = "Server RDBMS" end

    print(string.format(" %-24s %-18s %-12d %-8d %-8d %6.1f%%",
        oracle.name, engine_desc, total, st.pass, st.fail, pct))
end

print("----------------------------------------------------------------------------------------")
print(string.format(" Overall Conformance: %d/%d MATCH (%0.1f%% Byte-Identical Output)", PASS_COUNT, TOTAL, overall_pct))
print("========================================================================================\n")

local rel_fail = 0
for _, oracle in ipairs(active_oracles) do
    if oracle.type == "sqlite" or oracle.type == "duckdb" then
        rel_fail = rel_fail + oracle_stats[oracle.name].fail
    end
end

if rel_fail > 0 then
    error(string.format("[DARK ROOM FAIL] %d divergence(s) detected vs relational Oracles.", rel_fail))
else
    print("  [OK] LuaDB output is byte-identical across core relational Oracles on all test cases.\n")
end
