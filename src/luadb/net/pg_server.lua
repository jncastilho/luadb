local pg_server = {}

local ffi_ok, ffi = pcall(require, "ffi")

if ffi_ok then
    pcall(ffi.cdef, [[
        typedef unsigned short sa_family_t;
        typedef unsigned short in_port_t;
        typedef unsigned int in_addr_t;

        struct in_addr {
            in_addr_t s_addr;
        };

        struct sockaddr_in {
            sa_family_t sin_family;
            in_port_t sin_port;
            struct in_addr sin_addr;
            unsigned char sin_zero[8];
        };

        int socket(int domain, int type, int protocol);
        int bind(int sockfd, const struct sockaddr_in *addr, unsigned int addrlen);
        int listen(int sockfd, int backlog);
        int accept(int sockfd, struct sockaddr_in *addr, unsigned int *addrlen);
        ssize_t read(int fd, void *buf, size_t count);
        ssize_t write(int fd, const void *buf, size_t count);
        int close(int fd);
        int setsockopt(int sockfd, int level, int optname, const void *optval, unsigned int optlen);
        int fcntl(int fd, int cmd, int arg);
        int usleep(unsigned int usec);
        int *__errno_location(void);
    ]])
end

local function htons(n)
    return math.floor(n / 256) + (n % 256) * 256
end

-- Pure Lua Big-Endian 32-bit Integer Packer (Guaranteed String Output)
local function pack_u32(n)
    n = math.floor(tonumber(n) or 0)
    local b1 = math.floor(n / 16777216) % 256
    local b2 = math.floor(n / 65536) % 256
    local b3 = math.floor(n / 256) % 256
    local b4 = math.floor(n) % 256
    return string.char(b1, b2, b3, b4)
end

-- Helper to construct byte-perfect PostgreSQL Wire Protocol messages
function pg_server.make_msg(type_char, payload)
    payload = tostring(payload or "")
    local len = #payload + 4
    return type_char .. pack_u32(len) .. payload
end

-- Helper to construct ParameterStatus ('S') messages
function pg_server.make_param(name, value)
    local payload = name .. "\0" .. value .. "\0"
    return pg_server.make_msg("S", payload)
end

local function make_col_desc(cname, type_oid)
    type_oid = type_oid or 25
    local type_bytes = pack_u32(type_oid)
    local type_size = (type_oid == 23 or type_oid == 700) and "\0\4" or "\255\255"
    return cname .. "\0\0\0\0\0\0\0" .. type_bytes .. type_size .. "\255\255\255\255\0\0"
end

function pg_server.start(db, port)
    if not ffi_ok then
        error("PostgreSQL Server gateway requires LuaJIT / FFI environment")
    end

    port = port or 5433
    local AF_INET = 2
    local SOCK_STREAM = 1
    local SOL_SOCKET = 1
    local SO_REUSEADDR = 2
    local F_GETFL = 3
    local F_SETFL = 4
    local O_NONBLOCK = 2048

    local server_fd = ffi.C.socket(AF_INET, SOCK_STREAM, 0)
    if server_fd < 0 then
        error("Failed to create server socket")
    end

    local opt = ffi.new("int[1]", 1)
    ffi.C.setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, opt, ffi.sizeof(opt))

    local addr = ffi.new("struct sockaddr_in")
    addr.sin_family = AF_INET
    addr.sin_port = htons(port)
    addr.sin_addr.s_addr = 0 -- INADDR_ANY

    if ffi.C.bind(server_fd, addr, ffi.sizeof(addr)) < 0 then
        ffi.C.close(server_fd)
        error("Failed to bind socket to port " .. port)
    end

    if ffi.C.listen(server_fd, 50) < 0 then
        ffi.C.close(server_fd)
        error("Failed to listen on socket")
    end

    -- Set server socket to non-blocking
    local flags = ffi.C.fcntl(server_fd, F_GETFL, 0)
    ffi.C.fcntl(server_fd, F_SETFL, bit.bor(flags, O_NONBLOCK))

    print("=========================================================")
    print("  LuaDB Multi-Client PostgreSQL Wire Protocol Gateway")
    print("  Listening for DBeaver / psql connections on port " .. port)
    print("  Connection String: postgresql://localhost:" .. port .. "/luadb")
    print("=========================================================\n")

    local clients = {}
    local buf = ffi.new("char[16384]")

    while true do
        -- 1. Accept new incoming clients (non-blocking)
        local client_addr = ffi.new("struct sockaddr_in")
        local addr_len = ffi.new("unsigned int[1]", ffi.sizeof(client_addr))
        local client_fd = ffi.C.accept(server_fd, client_addr, addr_len)

        if client_fd >= 0 then
            local c_flags = ffi.C.fcntl(client_fd, F_GETFL, 0)
            ffi.C.fcntl(client_fd, F_SETFL, bit.bor(c_flags, O_NONBLOCK))
            clients[client_fd] = { fd = client_fd, state = "STARTUP" }
            print("[Client Connected] fd=" .. client_fd)
        end

        -- 2. Process non-blocking data across all active clients
        for fd, client in pairs(clients) do
            local n = ffi.C.read(fd, buf, 16384)
            if n > 0 then
                client.buf = (client.buf or "") .. ffi.string(buf, n)
                pg_server._process_client_stream(db, client)
            elseif n == 0 then
                print("[Client Disconnected] fd=" .. fd)
                ffi.C.close(fd)
                clients[fd] = nil
            else
                local err_num = ffi.C.__errno_location()[0]
                if err_num ~= 11 and err_num ~= 115 then -- EAGAIN (11) / EWOULDBLOCK
                    print("[Client Socket Error] fd=" .. fd .. " errno=" .. err_num)
                    ffi.C.close(fd)
                    clients[fd] = nil
                end
            end
        end

        if db.replicator then
            db.replicator:process_pending_queue()
        end

        ffi.C.usleep(1000) -- Sleep 1ms to conserve CPU
    end
end

function pg_server._send_bytes(fd, data)
    ffi.C.write(fd, data, #data)
end

-- Process incoming TCP byte stream by splitting concatenated PostgreSQL protocol frames
function pg_server._process_client_stream(db, client)
    local fd = client.fd
    local pkt = client.buf or ""

        -- Handle Inter-Node Cluster Replication frame ('R' or 'A')
        if #pkt >= 5 and (pkt:sub(1, 1) == "R" or pkt:sub(1, 1) == "A") and client.state == "STARTUP" then
            local proto = require("luadb.cluster.proto")
            local msg, rest = proto.parse_msg(pkt)
            if msg then
                client.buf = rest
                if msg.type == "R" and db.replicator then
                    local ok, ack = db.replicator:receive_replication(msg.payload)
                    if ok and ack then
                        pg_server._send_bytes(fd, ack)
                    end
                end
                return
            end
        end

        -- Handle SSL Request (804571 / 0x04d2162f or 804570 / 0x04d2162e) -> Respond 'N'
        if #pkt >= 8 and (pkt:sub(5, 8) == "\04\210\22\47" or pkt:sub(5, 8) == "\04\210\22\48" or pkt:sub(5, 8) == "\04\210\22\46") then
        print("[SSL Request] fd=" .. fd .. " -> Sending 'N'")
        pg_server._send_bytes(fd, "N")
        client.buf = pkt:sub(9)
        pkt = client.buf
    end

    if client.state == "STARTUP" and #pkt >= 8 then
        print("[Startup Packet] fd=" .. fd .. " -> Sending Protocol Handshake")
        -- Send Byte-Perfect PostgreSQL Protocol Handshake
        local auth_ok    = pg_server.make_msg("R", pack_u32(0))
        local param_ver  = pg_server.make_param("server_version", "14.0")
        local param_enc  = pg_server.make_param("client_encoding", "UTF8")
        local param_sp   = pg_server.make_param("search_path", "public")
        local param_su   = pg_server.make_param("is_superuser", "on")
        local param_auth = pg_server.make_param("session_authorization", "postgres")
        local param_id   = pg_server.make_param("integer_datetimes", "on")
        local param_sc   = pg_server.make_param("standard_conforming_strings", "on")
        local param_tz   = pg_server.make_param("TimeZone", "UTC")
        local key_data   = pg_server.make_msg("K", pack_u32(1234) .. pack_u32(5678))
        local ready      = pg_server.make_msg("Z", "I")

        pg_server._send_bytes(fd, auth_ok .. param_ver .. param_enc .. param_sp .. param_su .. param_auth .. param_id .. param_sc .. param_tz .. key_data .. ready)
        client.state = "READY"
        client.ready = ready
        client.buf = ""
        return
    end

    -- Loop through all concatenated protocol messages in pkt stream
    local pos = 1
    local pkt_len = #pkt
    local ready = client.ready or pg_server.make_msg("Z", "I")

    while pos <= pkt_len do
        local tag = pkt:sub(pos, pos)
        if pos + 4 > pkt_len + 1 then break end

        local b1, b2, b3, b4 = string.byte(pkt, pos + 1, pos + 4)
        local msg_len = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
        local next_pos = pos + 1 + msg_len
        if next_pos - 1 > pkt_len then break end

        local frame = pkt:sub(pos, next_pos - 1)

        if tag == "Q" then -- Simple Query
            local sql = frame:sub(6, #frame - 1):gsub("%s*;%s*$", "")
            print("[SQL Simple Query] fd=" .. fd .. ": " .. sql)
            pg_server._execute_and_respond(db, fd, sql, ready)

        elseif tag == "P" then -- Parse (Extended Query)
            local null_pos = frame:find("\0", 6)
            if null_pos then
                client.pending_sql = frame:sub(null_pos + 1):match("^([^%z]+)")
                print("[Extended Parse] fd=" .. fd .. ": " .. tostring(client.pending_sql))
            end
            pg_server._send_bytes(fd, "1\00\00\00\04") -- ParseComplete ('1')

        elseif tag == "B" then -- Bind
            -- Extract binary parameter values from Bind frame
            local params = {}
            local p_str = frame:match("%z([%w_%.%-%s]+)%z")
            if p_str then
                table.insert(params, p_str)
            else
                table.insert(params, "luadb")
            end
            client.bound_params = params
            pg_server._send_bytes(fd, "2\00\00\00\04") -- BindComplete ('2')

        elseif tag == "D" then -- Describe
            local desc_type = frame:sub(6, 6)
            if desc_type == "S" or desc_type == "P" then
                if client.pending_sql then
                    local ok, rows = pcall(function() return db:exec(client.pending_sql) end)
                    if ok and type(rows) == "table" and rows.message == nil then
                        local cols = {}
                        if #rows > 0 then
                            for k, _ in pairs(rows[1]) do table.insert(cols, k) end
                            table.sort(cols)
                        else
                            cols = { "id" }
                        end
                        local t_payload = { string.char(math.floor(#cols / 256), #cols % 256) }
                        for _, cname in ipairs(cols) do
                            table.insert(t_payload, make_col_desc(cname, 25))
                        end
                        pg_server._send_bytes(fd, pg_server.make_msg("T", table.concat(t_payload)))
                        client.described_sql = client.pending_sql
                    else
                        pg_server._send_bytes(fd, pg_server.make_msg("n", "")) -- NoData ('n')
                    end
                else
                    pg_server._send_bytes(fd, pg_server.make_msg("n", ""))
                end
            end

        elseif tag == "E" then -- Execute
            if client.pending_sql then
                print("[Extended Execute] fd=" .. fd .. ": " .. tostring(client.pending_sql))
                pg_server._execute_and_respond(db, fd, client.pending_sql, "", client)
            else
                pg_server._send_bytes(fd, pg_server.make_msg("C", "SELECT 0\0"))
            end

        elseif tag == "S" then -- Sync
            pg_server._send_bytes(fd, ready)

        elseif tag == "X" then -- Terminate
            print("[Terminate Connection] fd=" .. fd)
            ffi.C.close(fd)
            break
        end

        pos = (next_pos > pos) and next_pos or (pos + 1)
    end
    client.buf = pkt:sub(pos)
end

function pg_server._execute_and_respond(db, fd, sql, ready_suffix, client)
    if not sql or sql == "" then
        pg_server._send_bytes(fd, pg_server.make_msg("C", "SELECT 0\0") .. ready_suffix)
        return
    end

    local ok, rows, err = pcall(function() return db:exec(sql, client and client.bound_params) end)
    if not ok then
        err = tostring(rows)
        rows = nil
    end

    if err then
        print("[SQL Error] fd=" .. fd .. ": " .. err)
        local err_payload = "SFATAL\0M" .. err .. "\0\0"
        local err_msg = pg_server.make_msg("E", err_payload)
        pg_server._send_bytes(fd, err_msg .. ready_suffix)
    elseif type(rows) == "table" and rows.message == nil then
        local already_described = (client and client.described_sql == sql)
        if already_described then
            client.described_sql = nil -- reset
        end

        if #rows > 0 then
            local cols = {}
            for k, _ in pairs(rows[1]) do table.insert(cols, k) end
            table.sort(cols)
            local col_count = #cols

            if not already_described then
                -- Build RowDescription 'T'
                local t_payload = { string.char(math.floor(col_count / 256), col_count % 256) }
                for _, cname in ipairs(cols) do
                    table.insert(t_payload, make_col_desc(cname, 25))
                end
                local desc_msg = pg_server.make_msg("T", table.concat(t_payload))
                pg_server._send_bytes(fd, desc_msg)
            end

            -- Send DataRows 'D'
            for _, r in ipairs(rows) do
                local d_parts = { string.char(math.floor(col_count / 256), col_count % 256) }
                for _, cname in ipairs(cols) do
                    local val_str = tostring(r[cname] ~= nil and r[cname] or "")
                    table.insert(d_parts, pack_u32(#val_str) .. val_str)
                end
                local d_str = table.concat(d_parts)
                pg_server._send_bytes(fd, pg_server.make_msg("D", d_str))
            end

            local complete = pg_server.make_msg("C", "SELECT " .. #rows .. "\0")
            pg_server._send_bytes(fd, complete .. ready_suffix)
        else
            -- Empty result set: Send default single-column RowDescription 'T' (id INT4) + SELECT 0 if not described
            local complete = pg_server.make_msg("C", "SELECT 0\0")
            if not already_described then
                local default_desc = pg_server.make_msg("T", "\0\1" .. make_col_desc("id", 23))
                pg_server._send_bytes(fd, default_desc .. complete .. ready_suffix)
            else
                pg_server._send_bytes(fd, complete .. ready_suffix)
            end
        end
    else
        local cmd_word = sql:match("^%s*(%w+)") or "OK"
        cmd_word = cmd_word:upper()
        local status_msg = "OK"
        if cmd_word == "SET" then status_msg = "SET"
        elseif cmd_word == "SHOW" then status_msg = "SHOW"
        elseif cmd_word == "BEGIN" then status_msg = "BEGIN"
        elseif cmd_word == "COMMIT" then status_msg = "COMMIT"
        elseif cmd_word == "ROLLBACK" then status_msg = "ROLLBACK"
        elseif cmd_word == "CREATE" then status_msg = "CREATE TABLE"
        elseif cmd_word == "INSERT" then status_msg = "INSERT 0 1"
        elseif cmd_word == "UPDATE" then status_msg = "UPDATE 1"
        elseif cmd_word == "DELETE" then status_msg = "DELETE 1"
        elseif cmd_word == "DROP" then status_msg = "DROP TABLE"
        elseif cmd_word == "ALTER" then status_msg = "ALTER TABLE"
        elseif cmd_word == "REINDEX" then status_msg = "REINDEX"
        end

        local complete = pg_server.make_msg("C", status_msg .. "\0")
        pg_server._send_bytes(fd, complete .. ready_suffix)
    end
end

return pg_server
