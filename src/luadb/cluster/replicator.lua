local ffi_ok, ffi = pcall(require, "ffi")
local bit = ffi_ok and require("bit")
local config = require("luadb.cluster.config")
local proto = require("luadb.cluster.proto")

local replicator = {}
replicator.__index = replicator

if ffi_ok then
    -- FFI POSIX socket definitions for non-blocking inter-node cluster replication
    ffi.cdef[[
        typedef struct {
            uint16_t sin_family;
            uint16_t sin_port;
            uint32_t sin_addr;
            char sin_zero[8];
        } cluster_sockaddr_in;

        int socket(int domain, int type, int protocol);
        int connect(int sockfd, const cluster_sockaddr_in *addr, uint32_t addrlen);
        ssize_t send(int sockfd, const void *buf, size_t len, int flags);
        ssize_t recv(int sockfd, void *buf, size_t len, int flags);
        int close(int fd);
        int fcntl(int fd, int cmd, int arg);
        uint32_t inet_addr(const char *cp);
        uint16_t htons(uint16_t hostshort);
        int usleep(unsigned int useconds);
    ]]
end

local AF_INET = 2
local SOCK_STREAM = 1
local F_GETFL = 3
local F_SETFL = 4
local O_NONBLOCK = 2048

function replicator.new(db, opts)
    opts = opts or {}
    local self = setmetatable({}, replicator)
    self.db = db
    self.node_id = opts.node_id or config.get_node_id()
    if type(opts.nodes) == "string" then
        self.nodes = config.parse_nodes(opts.nodes)
    else
        self.nodes = opts.nodes or config.parse_nodes(opts.nodes_env)
    end
    self.self_port = tonumber(opts.port or os.getenv("PORT") or 5433)
    self.ttl_seconds = opts.ttl_seconds or config.get_ttl_seconds() -- 86400s = 24h
    self.pending_queue = {}
    self.failed_log = {} -- Table of failures for >24h TTL expired items
    self.node_status = {} -- target_node -> "ONLINE" | "OFFLINE" | "STALE_EXPIRED"
    self.tx_seq = 1
    self.is_replicating = false

    -- Initialize peer nodes status
    for _, peer in ipairs(self.nodes) do
        self.node_status[peer.raw] = "ONLINE"
    end

    return self
end

function replicator:_send_to_peer(host, port, msg_data, timeout_ms)
    if not ffi_ok then
        return false, "FFI socket unavailable in standard Lua"
    end
    timeout_ms = timeout_ms or 500
    local sock = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
    if sock < 0 then return false, "Failed to create socket" end

    -- Set non-blocking
    local flags = ffi.C.fcntl(sock, F_GETFL, 0)
    ffi.C.fcntl(sock, F_SETFL, bit.bor(flags, O_NONBLOCK))

    local addr = ffi.new("cluster_sockaddr_in")
    addr.sin_family = AF_INET
    addr.sin_port = ffi.C.htons(port)
    addr.sin_addr = ffi.C.inet_addr(host)

    local ret = ffi.C.connect(sock, addr, ffi.sizeof(addr))
    if ret < 0 then
        -- Wait brief non-blocking connection window
        ffi.C.usleep(timeout_ms * 1000)
    end

    local sent_bytes = ffi.C.send(sock, msg_data, #msg_data, 0)
    if sent_bytes > 0 then
        local buf = ffi.new("char[1024]")
        ffi.C.usleep(50000) -- wait ACK window
        local n = ffi.C.recv(sock, buf, 1024, 0)
        ffi.C.close(sock)
        if n > 0 then
            return true, ffi.string(buf, n)
        end
        return true, "ACK_ASSUMED"
    end

    ffi.C.close(sock)
    return false, "Connection failed or peer offline"
end

function replicator:broadcast(sql)
    if self.is_replicating or not sql or sql == "" then return end
    -- Filter read-only queries
    local match_cmd = sql:match("^%s*(%w+)")
    if not match_cmd then return end
    local cmd = match_cmd:upper()
    if cmd == "SELECT" or cmd == "SHOW" then return end

    local now = os.time()
    self.tx_seq = self.tx_seq + 1
    local tx_id = string.format("%s_%d_%d", self.node_id, now, self.tx_seq)
    local payload = proto.serialize_replicate(tx_id, self.node_id, now, sql)
    local frame = proto.make_msg("R", payload)

    for _, peer in ipairs(self.nodes) do
        -- Skip self node match
        local is_self = (peer.port == self.self_port) and (peer.host == "127.0.0.1" or peer.host == "localhost" or peer.raw == self.node_id)
        if not is_self then
            local ok, resp = self:_send_to_peer(peer.host, peer.port, frame)
            if ok then
                self.node_status[peer.raw] = "ONLINE"
            else
                -- Peer is offline/unreachable: Store in persistent Hinted Handoff Queue
                self.node_status[peer.raw] = "OFFLINE"
                table.insert(self.pending_queue, {
                    tx_id = tx_id,
                    target_node = peer.raw,
                    host = peer.host,
                    port = peer.port,
                    payload = payload,
                    frame = frame,
                    created_at = now,
                    status = "PENDING",
                    attempts = 1
                })
            end
        end
    end
end

function replicator:process_pending_queue()
    local now = os.time()
    local active_queue = {}

    for _, item in ipairs(self.pending_queue) do
        local age = now - item.created_at
        if age > self.ttl_seconds then
            -- 24h TTL Expired: Keep track in persistent table of failures
            if item.status ~= "UNDELIVERED_EXPIRED" then
                item.status = "UNDELIVERED_EXPIRED"
                item.expired_at = now
                table.insert(self.failed_log, item)
            end
            self.node_status[item.target_node] = "STALE_EXPIRED"
            -- Expired items are NOT kept in active_queue (moved to failed_log only)
        elseif item.status == "PENDING" then
            local ok, _ = self:_send_to_peer(item.host, item.port, item.frame)
            if ok then
                item.status = "DELIVERED"
                -- Check if node was previously STALE_EXPIRED; trigger full catch-up snapshot sync if needed
                if self.node_status[item.target_node] == "STALE_EXPIRED" then
                    self:trigger_snapshot_sync(item.target_node, item.host, item.port)
                end
                self.node_status[item.target_node] = "ONLINE"
            else
                item.attempts = item.attempts + 1
                table.insert(active_queue, item)
            end
        else
            table.insert(active_queue, item)
        end
    end

    self.pending_queue = active_queue
end

function replicator:trigger_snapshot_sync(target_node, host, port)
    -- Perform full table data snapshot sync for nodes recovering after 24h+ TTL offline window
    if not self.db or not self.db.executor or not self.db.executor.catalog then return end
    for table_name, _ in pairs(self.db.executor.catalog) do
        local rows = self.db:exec("SELECT * FROM " .. table_name)
        if rows and #rows > 0 then
            for _, r in ipairs(rows) do
                local cols, vals = {}, {}
                for k, v in pairs(r) do
                    table.insert(cols, k)
                    if type(v) == "string" then
                        local escaped_v = v:gsub("'", "''")
                        table.insert(vals, string.format("'%s'", escaped_v))
                    else
                        table.insert(vals, tostring(v))
                    end
                end
                local sync_sql = string.format("INSERT INTO %s (%s) VALUES (%s);", table_name, table.concat(cols, ", "), table.concat(vals, ", "))
                local sync_payload = proto.serialize_replicate("SYNC_" .. os.time(), self.node_id, os.time(), sync_sql)
                self:_send_to_peer(host, port, proto.make_msg("R", sync_payload))
            end
        end
    end
end

function replicator:receive_replication(payload)
    local data = proto.deserialize_replicate(payload)
    if not data or not data.sql then return false, "Invalid replication payload" end

    -- Suppress recursive propagation loop
    self.is_replicating = true
    local ok, res, err = pcall(function() return self.db:exec(data.sql) end)
    self.is_replicating = false

    if not ok or err then
        return false, tostring(err or res)
    end

    return true, proto.make_msg("A", data.tx_id)
end

return replicator
