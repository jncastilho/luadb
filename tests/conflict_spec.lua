package.path = "src/?.lua;src/?/init.lua;" .. package.path

local luadb = require("luadb")
local ConflictResolver = require("luadb.cluster.conflict")
local Replicator = require("luadb.cluster.replicator")
local proto = require("luadb.cluster.proto")

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("ASSERT FAILED: [%s] Expected %s, got %s", msg or "test", tostring(expected), tostring(actual)))
    else
        print(string.format("  ✓ [OK] %s: %s", msg or "check", tostring(actual)))
    end
end

-- Clean up leftover test database files
for _, file in ipairs({ "c_db_A.db", "c_db_B.db", "c_db_N1.db", "c_db_N2.db", "c_node_east.db", "c_node_west.db" }) do
    os.remove(file)
end

print("\n--------------------------------------------------")
print("[TEST SUITE] Master-Master Conflict Resolution & LWW Engine")
print("--------------------------------------------------")

-- 1. Test ConflictResolver Pure LWW & Deterministic Node-ID Tie Breaking
print("\n[Conflict Test 1] LWW & Node-ID Tie-Breaking Algorithm")
local cr = ConflictResolver.new("node_us_east")

cr:set_row_version("conflict_orders", 101, 1000200, "node_us_east")
local v1 = cr:get_row_version("conflict_orders", 101)
assert_eq(v1.hlc_ts, 1000200, "Recorded Row Version Microsecond Timestamp")
assert_eq(v1.node_id, "node_us_east", "Recorded Row Version Node ID")

-- Newer incoming timestamp (1000500 > 1000200) -> Should Apply
local apply_newer, r_newer = cr:should_apply("conflict_orders", 101, 1000500, "node_eu_west")
assert_eq(apply_newer, true, "Newer Timestamp Apply Decision")
assert_eq(r_newer, "INCOMING_NEWER", "Newer Timestamp Reason")

-- Older incoming timestamp (1000100 < 1000200) -> Should Reject
local apply_older, r_older = cr:should_apply("conflict_orders", 101, 1000100, "node_eu_west")
assert_eq(apply_older, false, "Older Timestamp Reject Decision")
assert_eq(r_older, "LOCAL_NEWER", "Older Timestamp Reason")

-- Identical timestamp (1000200 == 1000200) with higher Node ID ("node_z" > "node_us_east") -> Should Apply
local apply_tie_win, r_tie_win = cr:should_apply("conflict_orders", 101, 1000200, "node_z")
assert_eq(apply_tie_win, true, "Tie-Break Higher Node ID Decision")
assert_eq(r_tie_win, "TIE_BREAK_INCOMING_WINS", "Tie-Break Higher Node ID Reason")

-- Identical timestamp (1000200 == 1000200) with lower Node ID ("node_a" < "node_us_east") -> Should Reject
local apply_tie_lose, r_tie_lose = cr:should_apply("conflict_orders", 101, 1000200, "node_a")
assert_eq(apply_tie_lose, false, "Tie-Break Lower Node ID Decision")
assert_eq(r_tie_lose, "TIE_BREAK_LOCAL_WINS", "Tie-Break Lower Node ID Reason")


-- 2. Test Active-Active Master-Master Concurrent Mutation LWW Convergence
print("\n[Conflict Test 2] Master-Master Concurrent LWW Convergence")
local db_A = luadb.open({ driver = "memory", storage_path = "c_db_A.db", node_id = "node_alpha" })
local db_B = luadb.open({ driver = "memory", storage_path = "c_db_B.db", node_id = "node_beta" })

db_A:exec("CREATE TABLE conflict_accounts (id INT PRIMARY KEY, holder TEXT, balance REAL);")
db_B:exec("CREATE TABLE conflict_accounts (id INT PRIMARY KEY, holder TEXT, balance REAL);")

local base_ts = ConflictResolver.now_us()
local t0 = base_ts
local t1 = base_ts + 1000
local t2 = base_ts + 5000

-- Initial seed row
db_A:exec("INSERT INTO conflict_accounts VALUES (1, 'Alice', 500.0);")
db_A.replicator.conflict_resolver:set_row_version("conflict_accounts", 1, t0, "node_alpha")

local seed_payload = proto.serialize_replicate("tx_0", "node_alpha", t0, "INSERT INTO conflict_accounts VALUES (1, 'Alice', 500.0);", "conflict_accounts", 1)
db_B.replicator:receive_replication(seed_payload)

-- Node A updates row 1 at T=t1
local sql_A = "UPDATE conflict_accounts SET balance = 600.0 WHERE id = 1;"
db_A:exec(sql_A)
db_A.replicator.conflict_resolver:set_row_version("conflict_accounts", 1, t1, "node_alpha")

-- Node B updates row 1 concurrently at T=t2 (newer write)
local sql_B = "UPDATE conflict_accounts SET balance = 750.0 WHERE id = 1;"
db_B:exec(sql_B)
db_B.replicator.conflict_resolver:set_row_version("conflict_accounts", 1, t2, "node_beta")

-- Replicate older mutation A -> B (Should be dropped by B via LWW)
local payload_A = proto.serialize_replicate("tx_A1", "node_alpha", t1, sql_A, "conflict_accounts", 1)
local ok_B, _ = db_B.replicator:receive_replication(payload_A)
assert_eq(ok_B, true, "Node B Processed Replicated Payload A")

local row_B = db_B:exec("SELECT balance FROM conflict_accounts WHERE id = 1;")
assert_eq(row_B[1].balance, 750.0, "Node B Kept Newer LWW Value (750.0)")

-- Replicate newer mutation B -> A (Should be accepted by A via LWW)
local payload_B = proto.serialize_replicate("tx_B1", "node_beta", t2, sql_B, "conflict_accounts", 1)
local ok_A, _ = db_A.replicator:receive_replication(payload_B)
assert_eq(ok_A, true, "Node A Processed Replicated Payload B")

local row_A = db_A:exec("SELECT balance FROM conflict_accounts WHERE id = 1;")
assert_eq(row_A[1].balance, 750.0, "Node A Converged to Newer LWW Value (750.0)")


-- 3. Test Microsecond Timestamp Tie-Breaking on Identical Timestamps
print("\n[Conflict Test 3] Microsecond Timestamp Tie-Breaking")
local cr_N1 = ConflictResolver.new("node_1")
local cr_N2 = ConflictResolver.new("node_2")

local same_ts = cr_N1:now_us()
cr_N1:set_row_version("inventory", 10, same_ts, "node_1")
cr_N2:set_row_version("inventory", 10, same_ts, "node_2")

-- Node 1 evaluates incoming update from Node 2 ("node_2" > "node_1") -> Apply
local apply_N1, reason_N1 = cr_N1:should_apply("inventory", 10, same_ts, "node_2")
assert_eq(apply_N1, true, "Node 1 Accepts Node 2 Write via Tie-Break")
assert_eq(reason_N1, "TIE_BREAK_INCOMING_WINS", "Tie-Break Incoming Winner Reason")

-- Node 2 evaluates incoming update from Node 1 ("node_1" < "node_2") -> Reject
local apply_N2, reason_N2 = cr_N2:should_apply("inventory", 10, same_ts, "node_1")
assert_eq(apply_N2, false, "Node 2 Rejects Node 1 Write via Tie-Break")
assert_eq(reason_N2, "TIE_BREAK_LOCAL_WINS", "Tie-Break Local Winner Reason")


-- 4. Test Split-Brain Partition & Healing Reconciliation
print("\n[Conflict Test 4] Split-Brain Partition & Healing Reconciliation")
local node_east = luadb.open({ driver = "memory", storage_path = "c_node_east.db", node_id = "node_east", nodes = "127.0.0.1:9099" })
local node_west = luadb.open({ driver = "memory", storage_path = "c_node_west.db", node_id = "node_west", nodes = "127.0.0.1:9098" })

node_east:exec("CREATE TABLE conflict_settings (id INT PRIMARY KEY, val TEXT);")
node_west:exec("CREATE TABLE conflict_settings (id INT PRIMARY KEY, val TEXT);")

local sb_ts = ConflictResolver.now_us() + 20000
local ts_east = sb_ts + 1000
local ts_west = sb_ts + 5000 -- West node is newer

-- Partition state: node_west offline
-- node_east performs update at ts_east
node_east.replicator:broadcast("INSERT INTO conflict_settings VALUES (1, 'Config_East');", ts_east)
node_east:exec("INSERT INTO conflict_settings VALUES (1, 'Config_East');")
node_east.replicator.conflict_resolver:set_row_version("conflict_settings", 1, ts_east, "node_east")

-- While partitioned, node_west performs update at ts_west (newer)
node_west:exec("INSERT INTO conflict_settings VALUES (1, 'Config_West');")
node_west.replicator.conflict_resolver:set_row_version("conflict_settings", 1, ts_west, "node_west")

-- Network partition heals: node_east drains pending handoff frame to node_west
local pending_east_frame = node_east.replicator.pending_queue[1]
assert_eq(pending_east_frame ~= nil, true, "Pending Handoff Frame Exists on East Node")

local ok_drain, _ = node_west.replicator:receive_replication(pending_east_frame.payload)
assert_eq(ok_drain, true, "West Node Received Drained Handoff Frame")

local west_val = node_west:exec("SELECT val FROM conflict_settings WHERE id = 1;")
assert_eq(west_val[1].val, "Config_West", "West Node Protected Newer Partition Write (Config_West)")


-- 6. Test HLC Clock Catch-Up on Lagging Node
print("\n[Conflict Test 6] HLC Clock Catch-Up on Lagging Node")
local node_lagging = ConflictResolver.new("node_lagging")
local far_future_ts = 9999999999999000  -- Far future timestamp from Node A
local apply, _ = node_lagging:should_apply("orders", 1, far_future_ts, "node_leader")
assert_eq(apply, true, "Lagging Node Accepted Leader Write")

-- Node B (lagging) generates a subsequent local write: its HLC must be > far_future_ts
local next_local_ts = node_lagging:now_us()
assert_eq(next_local_ts > far_future_ts, true, "Lagging Node Clock Advanced Past Leader Timestamp")


-- 7. Test Conflict Version State Export / Import (Persistence Across Restart)
print("\n[Conflict Test 7] Conflict Version State Export & Import")
local cr_orig = ConflictResolver.new("node_persist")
cr_orig:set_row_version("users", 42, 5000000000000000, "node_persist")
local exported = cr_orig:export_state()

-- Create fresh node (simulating restart) and restore state
local cr_restarted = ConflictResolver.new("node_persist")
cr_restarted:import_state(exported)

local restored_ver = cr_restarted:get_row_version("users", 42)
assert_eq(restored_ver ~= nil, true, "Restored Version Exists After Restart")
assert_eq(restored_ver.hlc_ts, 5000000000000000, "Restored Timestamp Preserved Across Restart")

-- Stale update arriving after restart should be rejected (preventing resurrection)
local apply_stale_after_restart, reason = cr_restarted:should_apply("users", 42, 4000000000000000, "node_remote")
assert_eq(apply_stale_after_restart, false, "Stale Write Rejected After Restart")
assert_eq(reason, "LOCAL_NEWER", "Stale Write Rejection Reason")

print("\n[PASS] Master-Master Conflict Resolution & LWW Engine Suite Passed 100%!")
