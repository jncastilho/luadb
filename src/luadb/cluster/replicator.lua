local ffi_ok, ffi = pcall(require, "ffi")
local bit = ffi_ok and require("bit")
local config = require("luadb.cluster.config")
local proto = require("luadb.cluster.proto")
local ConflictResolver = require("luadb.cluster.conflict")

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

local function extract_mutation_meta(db, sql)
    if not sql or not db or not db.executor then return nil, nil end
    local ok, parser = pcall(require, "luadb.sql.parser")
    if not ok or not parser then return nil, nil end

    local ok_p, ast = pcall(parser.parse, sql)
    if not ok_p or not ast or not ast.table then return nil, nil end

    local table_name = ast.table
    local meta = db.executor.catalog and db.executor.catalog[table_name:lower()]
    if not meta then return table_name, nil end

    local pk_col_name, pk_col_idx = nil, nil
    for idx, col in ipairs(meta.columns) do
        if col.is_pk then
            pk_col_name = col.name
            pk_col_idx = idx
            break
        end
    end
    if not pk_col_name then
        pk_col_name = meta.columns[1] and meta.columns[1].name
        pk_col_idx = 1
    end
    if not pk_col_name then return table_name, nil end

    local pk_val = nil
    local cmd = ast.command and ast.command:upper()
    if cmd == "INSERT" and ast.values then
        pk_val = ast.values[pk_col_idx]
    elseif (cmd == "UPDATE" or cmd == "DELETE") and ast.where then
        if ast.where.left and ast.where.left:lower() == pk_col_name:lower() and ast.where.op == "=" then
            pk_val = ast.where.right
        end
    end

    return table_name, pk_val
end

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
    self.conflict_resolver = ConflictResolver.new(self.node_id)

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

function replicator:persist_state()
    if not self.db or self.is_replicating then return end
    self.is_replicating = true
    pcall(function()
        self.db:exec("CREATE TABLE IF NOT EXISTS _luadb_conflict_state (k TEXT PRIMARY KEY, v TEXT);")
        local json = require("luadb.sql.json")
        local state = self.conflict_resolver:export_state()
        local jstr = json.stringify(state)
        local escaped = jstr:gsub("'", "''")
        self.db:exec("DELETE FROM _luadb_conflict_state WHERE k = 'state';")
        self.db:exec("INSERT INTO _luadb_conflict_state VALUES ('state', '" .. escaped .. "');")
    end)
    self.is_replicating = false
end

function replicator:load_persistent_state()
    if not self.db then return end
    self.is_replicating = true
    pcall(function()
        local rows = self.db:exec("SELECT v FROM _luadb_conflict_state WHERE k = 'state';")
        if rows and rows[1] and rows[1].v then
            local json = require("luadb.sql.json")
            local state = json.parse(rows[1].v)
            if state then
                self.conflict_resolver:import_state(state)
            end
        end
    end)
    self.is_replicating = false
end

function replicator:broadcast(sql, override_ts)
    if self.is_replicating or not sql or sql == "" then return end
    if sql:upper():find("_LUADB_") then return end
    local match_cmd = sql:match("^%s*(%w+)")
    if not match_cmd then return end
    local cmd = match_cmd:upper()
    if cmd == "SELECT" or cmd == "SHOW" then return end

    local hlc_ts = override_ts or self.conflict_resolver:now_us()
    local pt_val = type(hlc_ts) == "table" and hlc_ts.pt or math.floor(tonumber(hlc_ts) or 0)
    local lc_val = type(hlc_ts) == "table" and hlc_ts.lc or 0

    self.tx_seq = self.tx_seq + 1
    local tx_id = string.format("%s_%.0f_%.0f_%d", self.node_id, pt_val, lc_val, self.tx_seq)

    local t_name, pk_val = extract_mutation_meta(self.db, sql)
    if t_name and pk_val ~= nil then
        self.conflict_resolver:set_row_version(t_name, pk_val, hlc_ts, self.node_id)
        self:persist_state()
    end

    local payload = proto.serialize_replicate(tx_id, self.node_id, hlc_ts, sql, t_name, pk_val)
    local frame = proto.make_msg("R", payload)

    for _, peer in ipairs(self.nodes) do
        local is_self = (peer.port == self.self_port) and (peer.host == "127.0.0.1" or peer.host == "localhost" or peer.raw == self.node_id)
        if not is_self then
            local ok, _ = self:_send_to_peer(peer.host, peer.port, frame)
            if ok then
                self.node_status[peer.raw] = "ONLINE"
            else
                self.node_status[peer.raw] = "OFFLINE"
                table.insert(self.pending_queue, {
                    tx_id = tx_id,
                    target_node = peer.raw,
                    host = peer.host,
                    port = peer.port,
                    payload = payload,
                    frame = frame,
                    created_at = math.floor(pt_val / 1000000),
                    hlc_ts = hlc_ts,
                    status = "PENDING",
                    attempts = 1
                })
            end
        end
    end
end

function replicator:process_pending_queue()
    local now_sec = os.time()
    local active_queue = {}

    for _, item in ipairs(self.pending_queue) do
        local age = now_sec - item.created_at
        if age > self.ttl_seconds then
            if item.status ~= "UNDELIVERED_EXPIRED" then
                item.status = "UNDELIVERED_EXPIRED"
                item.expired_at = now_sec
                table.insert(self.failed_log, item)
            end
            self.node_status[item.target_node] = "STALE_EXPIRED"
        elseif item.status == "PENDING" then
            local ok, _ = self:_send_to_peer(item.host, item.port, item.frame)
            if ok then
                item.status = "DELIVERED"
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
    if not self.db or not self.db.executor or not self.db.executor.catalog then return end
    for table_name, _ in pairs(self.db.executor.catalog) do
        local rows = self.db:exec("SELECT * FROM " .. table_name)
        if rows and #rows > 0 then
            for _, r in ipairs(rows) do
                local cols, vals = {}, {}
                local pk_val = r["id"] or r[1]
                for k, v in pairs(r) do
                    table.insert(cols, k)
                    if v == nil then
                        table.insert(vals, "NULL")
                    elseif type(v) == "string" then
                        local escaped_v = v:gsub("'", "''")
                        table.insert(vals, string.format("'%s'", escaped_v))
                    elseif type(v) == "boolean" then
                        table.insert(vals, v and "TRUE" or "FALSE")
                    else
                        table.insert(vals, tostring(v))
                    end
                end
                local sync_sql = string.format("INSERT INTO %s (%s) VALUES (%s);", table_name, table.concat(cols, ", "), table.concat(vals, ", "))
                local hlc_ts = self.conflict_resolver:now_us()
                local sync_payload = proto.serialize_replicate("SYNC_" .. hlc_ts, self.node_id, hlc_ts, sync_sql, table_name, pk_val)
                self:_send_to_peer(host, port, proto.make_msg("R", sync_payload))
            end
        end
    end
end

function replicator:receive_replication(payload)
    local data = proto.deserialize_replicate(payload)
    if not data or not data.sql then return false, "Invalid replication payload" end

    local t_name = data.table_name
    local pk_val = data.pk_val

    if not t_name or pk_val == nil then
        local extracted_t, extracted_pk = extract_mutation_meta(self.db, data.sql)
        t_name = t_name or extracted_t
        pk_val = pk_val or extracted_pk
    end

    -- Last-Write-Wins (LWW) Conflict Evaluation
    if t_name and pk_val ~= nil then
        local should_apply, reason = self.conflict_resolver:should_apply(t_name, pk_val, data.timestamp, data.origin_node)
        if not should_apply then
            local current = self.conflict_resolver:get_row_version(t_name, pk_val)
            self.conflict_resolver:record_conflict(
                t_name,
                pk_val,
                current and current.node_id or self.node_id,
                current and current.hlc_ts or 0,
                data.origin_node,
                data.timestamp,
                data.sql,
                reason
            )
            -- Acknowledge without applying stale write
            return true, proto.make_msg("A", data.tx_id)
        end
    end

    -- Suppress recursive propagation loop
    self.is_replicating = true
    local ok, res, err = pcall(function() return self.db:exec(data.sql) end)
    self.is_replicating = false

    if not ok or err then
        return false, tostring(err or res)
    end

    if t_name and pk_val ~= nil then
        self.conflict_resolver:set_row_version(t_name, pk_val, data.timestamp, data.origin_node)
    end

    return true, proto.make_msg("A", data.tx_id)
end

function replicator:get_conflict_log()
    return self.conflict_resolver.conflict_log
end

return replicator
