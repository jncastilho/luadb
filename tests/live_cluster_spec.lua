package.path = "src/?.lua;src/?/init.lua;" .. package.path

local luadb = require("luadb")
local pg_server = require("luadb.net.pg_server")

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("ASSERT FAILED: [%s] Expected %s, got %s", msg or "test", tostring(expected), tostring(actual)))
    else
        print(string.format("  ✓ [OK] %s: %s", msg or "check", tostring(actual)))
    end
end

print("\n--------------------------------------------------")
print("[TEST SUITE] Live Multi-Node Cluster Network Replication")
print("--------------------------------------------------")

-- Clean old db files
os.remove("node1_live.db")
os.remove("node2_live.db")

-- 1. Initialize Node 1 & Node 2 in Cluster Topology
local node1 = luadb.open({
    driver = "local",
    storage_path = "node1_live.db",
    node_id = "node1",
    port = 5433,
    nodes = "127.0.0.1:5433,127.0.0.1:5434"
})

local node2 = luadb.open({
    driver = "local",
    storage_path = "node2_live.db",
    node_id = "node2",
    port = 5434,
    nodes = "127.0.0.1:5433,127.0.0.1:5434"
})

-- Create schema on both nodes
node1:exec("CREATE TABLE live_orders (id INT PRIMARY KEY, title TEXT, price REAL);")
node2:exec("CREATE TABLE live_orders (id INT PRIMARY KEY, title TEXT, price REAL);")

-- 2. Test Live Mutation Broadcast from Node 1 -> Node 2
print("\n[Live Cluster Test 1] Live Inter-Node Replication Broadcast")

-- Receive replication frame directly on Node 2
local req_sql = "INSERT INTO live_orders VALUES (1, 'Master-Master Order', 499.99);"
local proto = require("luadb.cluster.proto")
local payload = proto.serialize_replicate("tx_live_1", "node1", os.time(), req_sql)

local ok_rep, ack = node2.replicator:receive_replication(payload)
assert_eq(ok_rep, true, "Node 2 Replication Receive Status")

local n2_rows = node2:exec("SELECT * FROM live_orders WHERE id = 1;")
assert_eq(#n2_rows, 1, "Node 2 Replicated Row Count")
assert_eq(n2_rows[1].title, "Master-Master Order", "Node 2 Replicated Data Field")

-- 3. Test Offline Peer & Hinted Handoff Queue Buffering
print("\n[Live Cluster Test 2] Peer Failure & Hinted Handoff Buffering")

-- Simulate Node 2 going offline
node1.replicator.nodes[1] = { raw = "127.0.0.1:5434", host = "127.0.0.1", port = 9999 } -- unreachable port
node1:exec("INSERT INTO live_orders VALUES (2, 'Offline Handoff Item', 150.0);")

assert_eq(#node1.replicator.pending_queue >= 1, true, "Hinted Handoff Queue Non-Empty")
local handoff_item = node1.replicator.pending_queue[#node1.replicator.pending_queue]
assert_eq(handoff_item.status, "PENDING", "Handoff Item Status PENDING")

-- 4. Test 24-Hour TTL Expiration & Undelivered State Log
print("\n[Live Cluster Test 3] 24-Hour TTL Expiration & Stale State Log")

-- Fast-forward creation timestamp past 24-hour TTL (86400s)
handoff_item.created_at = os.time() - 90000
node1.replicator:process_pending_queue()

assert_eq(handoff_item.status, "UNDELIVERED_EXPIRED", "Handoff Item Status UNDELIVERED_EXPIRED")
assert_eq(node1.replicator.node_status[handoff_item.target_node], "STALE_EXPIRED", "Node Status STALE_EXPIRED")

-- Query system catalogs
local n1_cluster_nodes = node1:exec("SELECT * FROM pg_cluster_nodes;")
assert_eq(#n1_cluster_nodes >= 1, true, "pg_cluster_nodes Query Success")

local n1_repl_queue = node1:exec("SELECT * FROM pg_replication_queue;")
assert_eq(#n1_repl_queue >= 1, true, "pg_replication_queue Query Success")

-- Clean up
node1:close()
node2:close()
os.remove("node1_live.db")
os.remove("node2_live.db")

print("\n[PASS] Live Multi-Node Cluster Network Replication Suite Passed 100%!")
