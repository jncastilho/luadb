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
assert_eq(v1.hlc_ts.pt, 1000200, "Recorded Row Version Microsecond Timestamp")
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
local t1 = { pt = base_ts.pt + 1000, lc = 0 }
local t2 = { pt = base_ts.pt + 5000, lc = 0 }

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

local sb_base = ConflictResolver.now_us()
local ts_east = { pt = sb_base.pt + 1000, lc = 0 }
local ts_west = { pt = sb_base.pt + 5000, lc = 0 } -- West node is newer

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
local far_future_ts = { pt = 9999999999999000, lc = 0 }  -- Far future timestamp from Node A
local apply, _ = node_lagging:should_apply("orders", 1, far_future_ts, "node_leader")
assert_eq(apply, true, "Lagging Node Accepted Leader Write")

-- Node B (lagging) generates a subsequent local write: its HLC must be > far_future_ts
local next_local_ts = node_lagging:now_us()
assert_eq(ConflictResolver.cmp_hlc(next_local_ts, far_future_ts) > 0, true, "Lagging Node Clock Advanced Past Leader Timestamp")


-- 7. Test Conflict Version State Export / Import (Persistence Across Restart)
print("\n[Conflict Test 7] Conflict Version State Export & Import")
local cr_orig = ConflictResolver.new("node_persist")
local test_hlc = { pt = 5000000000000000, lc = 5 }
cr_orig:set_row_version("users", 42, test_hlc, "node_persist")
local exported = cr_orig:export_state()

-- Create fresh node (simulating restart) and restore state
local cr_restarted = ConflictResolver.new("node_persist")
cr_restarted:import_state(exported)

local restored_ver = cr_restarted:get_row_version("users", 42)
assert_eq(restored_ver ~= nil, true, "Restored Version Exists After Restart")
assert_eq(ConflictResolver.cmp_hlc(restored_ver.hlc_ts, test_hlc) == 0, true, "Restored Timestamp Preserved Across Restart")

-- Stale update arriving after restart should be rejected (preventing resurrection)
local stale_ts = { pt = test_hlc.pt - 10000, lc = 0 }
local apply_stale_after_restart, reason = cr_restarted:should_apply("users", 42, stale_ts, "node_remote")
assert_eq(apply_stale_after_restart, false, "Stale Write Rejected After Restart")
assert_eq(reason, "LOCAL_NEWER", "Stale Write Rejection Reason")


-- 8. Test 10,000 HLC Logical Events Monotonicity (No 1,000 Wrapping)
print("\n[Conflict Test 8] 10,000 Logical Events Monotonic Clock Monotonicity")
local cr_mono = ConflictResolver.new("node_mono")
local prev_hlc = cr_mono:now_us()
local monotonic_ok = true

for i = 1, 10000 do
    local next_hlc = cr_mono:now_us()
    if ConflictResolver.cmp_hlc(prev_hlc, next_hlc) >= 0 then
        monotonic_ok = false
        error(string.format("Monotonicity violation at event %d: prev=%s >= next=%s", i, ConflictResolver.format_hlc(prev_hlc), ConflictResolver.format_hlc(next_hlc)))
    end
    prev_hlc = next_hlc
end
assert_eq(monotonic_ok, true, "10,000 Consecutive HLC Timestamps Strictly Monotonic (No 1000 Wrapping)")
assert_eq(cr_mono.logical_lc >= 10000, true, "Logical Counter Exceeds 10,000 without Truncation")


-- 9. Test End-to-End Database Restart Conflict Version Persistence
print("\n[Conflict Test 9] End-to-End Local Write Restart Conflict State Recovery")
os.remove("c_restart_test.db")
local db_p1 = luadb.open({ driver = "local", storage_path = "c_restart_test.db", node_id = "node_p1" })
db_p1:exec("CREATE TABLE p_orders (id INT PRIMARY KEY, amount REAL);")
db_p1:exec("INSERT INTO p_orders VALUES (100, 250.0);")

local hlc_before_close = db_p1.replicator.conflict_resolver:get_row_version("p_orders", 100).hlc_ts
db_p1:close()

-- Re-open database handle (simulating process restart)
local db_p2 = luadb.open({ driver = "local", storage_path = "c_restart_test.db", node_id = "node_p1" })
local ver_obj = db_p2.replicator.conflict_resolver:get_row_version("p_orders", 100)
local hlc_after_open = ver_obj and ver_obj.hlc_ts

assert_eq(hlc_after_open ~= nil, true, "Conflict Version Map Recovered Automatically on Open")
assert_eq(ConflictResolver.cmp_hlc(hlc_after_open, hlc_before_close) == 0, true, "Recovered Row HLC Timestamp Matches Pre-Restart State")

-- Verify a stale replication payload (older HLC) is rejected after restart
local stale_payload = proto.serialize_replicate("tx_stale", "node_remote", { pt = hlc_after_open.pt - 10000, lc = 0 }, "UPDATE p_orders SET amount = 10.0 WHERE id = 100;", "p_orders", 100)
local ok_stale, _ = db_p2.replicator:receive_replication(stale_payload)
assert_eq(ok_stale, true, "Replication Handler Executed Stale Check")

local post_restart_val = db_p2:exec("SELECT amount FROM p_orders WHERE id = 100;")
assert_eq(post_restart_val[1].amount, 250.0, "Stale Write Rejected After Restart (Amount Remained 250.0)")

db_p2:close()
os.remove("c_restart_test.db")


-- 10. Test Remotely Learned Mutation Version Persistence Across Process Restart
print("\n[Conflict Test 10] Remotely Received Replication Version Persistence Across Restart")
os.remove("c_remote_restart.db")
local db_r1 = luadb.open({ driver = "local", storage_path = "c_remote_restart.db", node_id = "node_local" })
db_r1:exec("CREATE TABLE r_items (id INT PRIMARY KEY, val TEXT);")
db_r1:exec("INSERT INTO r_items VALUES (5, 'Initial_Local');")

local r1_hlc = db_r1.replicator.conflict_resolver:get_row_version("r_items", 5).hlc_ts

-- Node B receives remote write from node_remote with higher HLC timestamp (e.g., pt+5000:lc=5)
local remote_newer_ts = { pt = r1_hlc.pt + 5000, lc = 5 }
local remote_payload = proto.serialize_replicate("tx_rem_1", "node_remote", remote_newer_ts, "UPDATE r_items SET val = 'Remote_Newer' WHERE id = 5;", "r_items", 5)
local ok_rem, _ = db_r1.replicator:receive_replication(remote_payload)
assert_eq(ok_rem, true, "Remote Replication Payload Received and Applied")

local val_applied = db_r1:exec("SELECT val FROM r_items WHERE id = 5;")
assert_eq(val_applied[1].val, "Remote_Newer", "Remote Write Applied in Memory")

-- Close DB handle without any subsequent local write (simulating node restart right after remote write)
db_r1:close()

-- Re-open DB handle (process restart)
local db_r2 = luadb.open({ driver = "local", storage_path = "c_remote_restart.db", node_id = "node_local" })
local r2_ver = db_r2.replicator.conflict_resolver:get_row_version("r_items", 5)
assert_eq(r2_ver ~= nil, true, "Remotely Learned Version Map Loaded from Disk Catalog")
assert_eq(ConflictResolver.cmp_hlc(r2_ver.hlc_ts, remote_newer_ts) == 0, true, "Remotely Learned Version Timestamp Restored")

-- Stale write with older timestamp (remote_newer_ts - 1000) arrives after restart
local remote_older_ts = { pt = remote_newer_ts.pt - 1000, lc = 0 }
local older_payload = proto.serialize_replicate("tx_rem_old", "node_remote", remote_older_ts, "UPDATE r_items SET val = 'Stale_Resurrected' WHERE id = 5;", "r_items", 5)
local ok_old, _ = db_r2.replicator:receive_replication(older_payload)
assert_eq(ok_old, true, "Older Stale Remote Replication Evaluated Post-Restart")

local val_post_restart = db_r2:exec("SELECT val FROM r_items WHERE id = 5;")
assert_eq(val_post_restart[1].val, "Remote_Newer", "Stale Remote Update Rejected Post-Restart (Value Remained Remote_Newer)")

db_r2:close()
os.remove("c_remote_restart.db")

print("\n[PASS] Master-Master Conflict Resolution & LWW Engine Suite Passed 100%!")
