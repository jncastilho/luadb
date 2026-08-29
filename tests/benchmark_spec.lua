package.path = "src/?.lua;src/?/init.lua;" .. package.path

local luadb = require("luadb")

print("\n--------------------------------------------------")
print("[BENCHMARK SUITE] LuaDB Performance & Memory Metrics")
print("--------------------------------------------------")

os.remove("bench.db")
local db = luadb.open({ driver = "local", storage_path = "bench.db" })
db:exec("CREATE TABLE bench (id INT PRIMARY KEY, title TEXT, score REAL);")

local count = 500

-- 1. Batch Write TPS Performance
print("\n[Benchmark 1] Write Throughput (INSERT TPS)")
local t0 = os.clock()
db:begin()
for i = 1, count do
    db:exec(string.format("INSERT INTO bench VALUES (%d, 'Item %d', %f);", i, i, i * 1.5))
end
db:commit()
local t1 = os.clock()
local duration_w = math.max(t1 - t0, 0.0001)
local write_tps = count / duration_w
print(string.format("  > Inserted %d records in %.4f sec (%.2f TPS)", count, duration_w, write_tps))

-- 2. Read Performance & Query Latency
print("\n[Benchmark 2] Read Throughput & Point Lookup Latency")
local t2 = os.clock()
local rows = db:exec("SELECT * FROM bench WHERE score > 500;")
local t3 = os.clock()
local duration_r = math.max(t3 - t2, 0.0001)
print(string.format("  > Queried %d matching rows in %.4f sec", #rows, duration_r))

-- 3. Memory & GC Footprint Metrics
print("\n[Benchmark 3] Memory Footprint & Garbage Collection Impact")
collectgarbage("collect")
local mem_kb = collectgarbage("count")
print(string.format("  > Active Lua Memory Footprint: %.2f KB", mem_kb))

db:close()
os.remove("bench.db")

print("\n[PASS] LuaDB Performance & Memory Metrics Completed Successfully!")
