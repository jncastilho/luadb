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
print("[TEST SUITE] Coroutines, Streaming Cursors & Parallel Ops")
print("--------------------------------------------------")

local db = luadb.open({ driver = "memory", storage_path = "coroutine_test.db" })

db:exec("CREATE TABLE logs (id INTEGER PRIMARY KEY, level TEXT, message TEXT);")

-- 1. Insert 50 records
for i = 1, 50 do
    db:exec(string.format("INSERT INTO logs VALUES (%d, 'INFO', 'Log entry #%d');", i, i))
end

-- 2. Test Coroutine Streaming Cursor
print("\n[Coroutine Test 1] Streaming Cursor Iterator (coroutine.yield)")
local count = 0
for row in db:cursor("SELECT * FROM logs ORDER BY id ASC;") do
    count = count + 1
    if count == 1 then
        assert_eq(row.message, "Log entry #1", "Streaming First Yielded Row")
    elseif count == 50 then
        assert_eq(row.message, "Log entry #50", "Streaming Last Yielded Row")
    end
end
assert_eq(count, 50, "Total Yielded Rows Count")

-- 3. Test Async Non-Blocking Coroutine Execution
print("\n[Coroutine Test 2] Non-Blocking Async Coroutine Execution")
local async_done = false
db:exec_async("SELECT COUNT(*) FROM logs;", {}, function(res, err)
    assert_eq(res[1].count_star, 50, "Async Coroutine Callback Execution")
    async_done = true
end)
assert_eq(async_done, true, "Async Task Completion")

db:close()

-- 4. Test Parallel Connection Pool
print("\n[Coroutine Test 3] Parallel Connection Pool Scheduler")
os.remove("pool_test.db")
local pool = luadb.pool(4, { driver = "local", storage_path = "pool_test.db" })

-- Initialize schema across pool connection 1
pool.connections[1]:exec("CREATE TABLE metrics (id INTEGER PRIMARY KEY, metric_val REAL);")

local queries = {
    "INSERT INTO metrics VALUES (1, 10.5);",
    "INSERT INTO metrics VALUES (2, 20.5);",
    "INSERT INTO metrics VALUES (3, 30.5);",
    "INSERT INTO metrics VALUES (4, 40.5);"
}

local parallel_res = pool:exec_parallel(queries)
assert_eq(#parallel_res, 4, "Parallel Queries Executed")
for idx, item in ipairs(parallel_res) do
    assert_eq(item.error, nil, "Parallel Query #" .. idx .. " Error State")
end

pool:close()
os.remove("pool_test.db")

print("\n[PASS] Coroutines & Parallel Ops Suite Completed Successfully!")
