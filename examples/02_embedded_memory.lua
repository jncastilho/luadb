package.path = "src/?.lua;src/?/init.lua;" .. package.path

local luadb = require("luadb")

print("==================================================")
print("  LuaDB Example 2: In-Memory High-Speed Database")
print("==================================================")

local db = luadb.open({
    driver = "memory",
    storage_path = "memory_session.db"
})

-- 1. Create Table for In-Memory Operations
db:exec([[
CREATE TABLE cache_items (
    item_key TEXT PRIMARY KEY,
    val_json JSONB,
    created_at TIMESTAMP
);
]])

-- 2. Bulk Insert JSON Records
print("\nInserting 100 in-memory JSON cache items...")
for i = 1, 100 do
    local json_payload = string.format('{"item_id": %d, "status": "%s", "tier": "gold"}', i, (i % 2 == 0) and "active" or "pending")
    db:exec(string.format("INSERT INTO cache_items VALUES ('key_%d', '%s', '2026-08-15 01:00:00');", i, json_payload))
end

-- 3. Query JSON attributes using ->> operator
local active_items = db:exec("SELECT item_key, val_json->>'status' AS status, val_json->>'tier' AS tier FROM cache_items WHERE val_json->>'status' = 'active';")
print(string.format("✓ Filtered Active Items Count: %d", #active_items))
print(string.format("  Sample Row 1: Item Key = %s, Status = %s, Tier = %s", active_items[1].item_key, active_items[1].status, active_items[1].tier))

-- 4. CTE Analytics Query
local cte_res = db:exec([[
WITH active_keys AS (
    SELECT item_key FROM cache_items WHERE val_json->>'status' = 'active'
)
SELECT COUNT(*) FROM active_keys;
]])

local active_count = cte_res[1] and (cte_res[1].count or cte_res[1].count_star or #cte_res)
print(string.format("✓ CTE Aggregation Count Result: %d", active_count))

db:close()
print("✓ In-Memory database closed.")
