package.path = "src/?.lua;src/?/init.lua;" .. package.path

local luadb = require("luadb")
local config = require("luadb.cluster.config")
local proto = require("luadb.cluster.proto")
local Replicator = require("luadb.cluster.replicator")

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("ASSERT FAILED: [%s] Expected %s, got %s", msg or "test", tostring(expected), tostring(actual)))
    else
        print(string.format("  ✓ [OK] %s: %s", msg or "check", tostring(actual)))
    end
end

print("\n--------------------------------------------------")
print("[TEST SUITE] Multi-Region Master-Master Coherence Engine")
print("--------------------------------------------------")

-- 1. Test Node Topology & Config Parsing
print("\n[Cluster Test 1] LUADB_NODES Topology Config Parsing")
local parsed_nodes = config.parse_nodes("127.0.0.1:5433, 10.0.0.5:5434, node3.us-east-1.internal:5435")
assert_eq(#parsed_nodes, 3, "Parsed Nodes Count")
assert_eq(parsed_nodes[1].host, "127.0.0.1", "Node 1 Host")
assert_eq(parsed_nodes[1].port, 5433, "Node 1 Port")
assert_eq(parsed_nodes[3].host, "node3.us-east-1.internal", "Node 3 Host")
assert_eq(parsed_nodes[3].port, 5435, "Node 3 Port")

-- 2. Test Inter-Node Protocol Framing
print("\n[Cluster Test 2] Inter-Node Replication Message Framing")
local payload = proto.serialize_replicate("tx_1001", "node_us_east", 1700000000, "INSERT INTO demo VALUES (1, 'Cloud');")
local frame = proto.make_msg("R", payload)
local parsed_msg, _ = proto.parse_msg(frame)
assert_eq(parsed_msg.type, "R", "Protocol Message Type")

local decoded_data = proto.deserialize_replicate(parsed_msg.payload)
assert_eq(decoded_data.tx_id, "tx_1001", "Decoded Transaction ID")
assert_eq(decoded_data.origin_node, "node_us_east", "Decoded Origin Node")
assert_eq(decoded_data.sql, "INSERT INTO demo VALUES (1, 'Cloud');", "Decoded SQL Mutation")

-- 3. Test Active-Active Peer Replication Receive
print("\n[Cluster Test 3] Peer Replication Receive & Execution")
local db_node2 = luadb.open({ driver = "memory", node_id = "node2" })
local rep_node2 = Replicator.new(db_node2, { node_id = "node2" })
db_node2:exec("CREATE TABLE orders (id INT PRIMARY KEY, product TEXT, price REAL);")

local repl_sql = "INSERT INTO orders VALUES (101, 'Laptop', 1299.99);"
local repl_payload = proto.serialize_replicate("tx_2001", "node1", os.time(), repl_sql)
local ok_recv, ack_frame = rep_node2:receive_replication(repl_payload)

assert_eq(ok_recv, true, "Replication Execution Status")
local orders = db_node2:exec("SELECT * FROM orders WHERE id = 101;")
assert_eq(#orders, 1, "Replicated Record Count")
assert_eq(orders[1].product, "Laptop", "Replicated Record Data Field")

-- 4. Test Hinted Handoff Queue Buffer on Offline Peer
print("\n[Cluster Test 4] Hinted Handoff Queue Buffer on Peer Offline")
local db_node1 = luadb.open({ driver = "memory", node_id = "node1", nodes = "127.0.0.1:9999" })
db_node1:exec("CREATE TABLE inventory (id INT PRIMARY KEY, item TEXT);")
db_node1:exec("INSERT INTO inventory VALUES (1, 'Widget');") -- Peer 9999 is offline

assert_eq(#db_node1.replicator.pending_queue, 2, "Buffered Pending Queue Length")
local pending_item = db_node1.replicator.pending_queue[2]
assert_eq(pending_item.status, "PENDING", "Pending Queue Item Status")
assert_eq(pending_item.target_node, "127.0.0.1:9999", "Pending Queue Target Node")

-- 5. Test 24-Hour TTL Expiration & Undelivered State Management
print("\n[Cluster Test 5] 24-Hour TTL Expiration & Undelivered State")
-- Simulate fast-forwarding time past 24-hour TTL (86400 seconds)
for _, item in ipairs(db_node1.replicator.pending_queue) do
    item.created_at = os.time() - 90000 -- 25 hours old
end
db_node1.replicator:process_pending_queue()

assert_eq(pending_item.status, "UNDELIVERED_EXPIRED", "Expired Queue Item Status")
assert_eq(db_node1.replicator.node_status["127.0.0.1:9999"], "STALE_EXPIRED", "Stale Expired Node State")

local cluster_nodes = db_node1:exec("SELECT * FROM pg_cluster_nodes;")
assert_eq(#cluster_nodes, 1, "Cluster Nodes Catalog Row Count")
assert_eq(cluster_nodes[1].status, "STALE_EXPIRED", "Catalog Node Status Field")

-- After expiration, pending_queue should be empty (expired items moved to failed_log)
local repl_queue = db_node1:exec("SELECT * FROM pg_replication_queue;")
assert_eq(#repl_queue, 0, "Replication Queue Catalog Row Count (expired items removed)")

local failed_log = db_node1:exec("SELECT * FROM pg_failed_replication_log;")
assert_eq(#failed_log, 2, "Failed Replication Log Row Count")
assert_eq(failed_log[1].status, "UNDELIVERED_EXPIRED", "Failed Log Status Field")

print("\n[PASS] Multi-Region Master-Master Coherence Engine Suite Passed 100%!")
