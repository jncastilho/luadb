package.path = "src/?.lua;src/?/init.lua;" .. package.path

local luadb = require("luadb")

print("==================================================")
print("  LuaDB Example 5: Kamailio SIP CDR Drain & Failover")
print("==================================================")

os.remove("kamailio_cdr_drain.db")

-- 1. Initialize local LuaDB store for Kamailio CDR persistence
local db = luadb.open({
    driver = "local",
    storage_path = "kamailio_cdr_drain.db"
})

-- 2. Create CDR Drain Buffer Table with published flag
db:exec([[
CREATE TABLE kamailio_cdrs (
    call_id TEXT PRIMARY KEY,
    caller TEXT,
    callee TEXT,
    duration INT,
    published BOOLEAN,
    created_at TIMESTAMP
);
]])

print("✓ Kamailio CDR Drain schema initialized.")

-- 3. Simulate Kamailio Lua script attempting to publish to Kafka (Kafka is OFFLINE)
print("\n[Simulating Kamailio SIP Call Ingestion while Kafka Broker is OFFLINE]")

local function on_sip_call_end(call_id, caller, callee, duration)
    local kafka_online = false -- Kafka broker down!
    local is_published = false

    if kafka_online then
        print(string.format("  -> Published CDR %s to Kafka topic 'sip-cdrs'", call_id))
        is_published = true
    else
        print(string.format("  ⚠️ Kafka unavailable! Buffering CDR %s locally to LuaDB (published = false)", call_id))
    end

    local sql = string.format("INSERT INTO kamailio_cdrs VALUES ('%s', '%s', '%s', %d, '%s', '2026-08-15 01:28:00');",
        call_id, caller, callee, duration, tostring(is_published))
    db:exec(sql)
end

-- Ingest 3 SIP CDRs during outage
on_sip_call_end("call-001@192.168.1.10", "+15550100", "+15550199", 45)
on_sip_call_end("call-002@192.168.1.10", "+15550101", "+15550198", 120)
on_sip_call_end("call-003@192.168.1.10", "+15550102", "+15550197", 12)

local unpub = db:exec("SELECT * FROM kamailio_cdrs WHERE published = 'false';")
print(string.format("\n✓ Buffered Pending CDR Count in LuaDB: %d", #unpub))

-- 4. Kafka Broker comes back ONLINE -> DRAIN QUEUE
print("\n[Kafka Broker Came Back ONLINE -> Running Drain Worker]")

local function drain_pending_cdrs()
    local pending = db:exec("SELECT * FROM kamailio_cdrs WHERE published = 'false';")
    local count = 0
    for _, cdr in ipairs(pending) do
        print(string.format("  🚀 Draining CDR %s (Caller: %s, Duration: %ds) -> Published to Kafka!", cdr.call_id, cdr.caller, cdr.duration))
        db:exec(string.format("UPDATE kamailio_cdrs SET published = 'true' WHERE call_id = '%s';", cdr.call_id))
        count = count + 1
    end
    return count
end

local drained_count = drain_pending_cdrs()
print(string.format("✓ Successfully drained %d CDRs to Kafka.", drained_count))

-- 5. Verify Queue is 100% Cleared
local remaining_pending = db:exec("SELECT * FROM kamailio_cdrs WHERE published = 'false';")
print(string.format("✓ Remaining Unpublished CDRs: %d", #remaining_pending))

db:close()
os.remove("kamailio_cdr_drain.db")
print("\n✓ Kamailio CDR Drain demonstration completed successfully.")
