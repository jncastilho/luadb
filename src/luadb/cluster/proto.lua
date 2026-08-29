local proto = {}

-- Message Header: 1 byte Type + 4 bytes Payload Length (Big Endian)
local function pack_u32(n)
    local b1 = math.floor(n / 16777216) % 256
    local b2 = math.floor(n / 65536) % 256
    local b3 = math.floor(n / 256) % 256
    local b4 = n % 256
    return string.char(b1, b2, b3, b4)
end

local function unpack_u32(str, pos)
    pos = pos or 1
    local b1, b2, b3, b4 = string.byte(str, pos, pos + 3)
    if not b1 or not b2 or not b3 or not b4 then return 0 end
    return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
end

function proto.make_msg(msg_type, payload)
    payload = payload or ""
    local len = #payload
    return msg_type .. pack_u32(len) .. payload
end

function proto.parse_msg(pkt)
    if not pkt or #pkt < 5 then return nil, "Incomplete header" end
    local msg_type = pkt:sub(1, 1)
    local len = unpack_u32(pkt, 2)
    if #pkt < 5 + len then return nil, "Incomplete payload" end
    local payload = pkt:sub(6, 5 + len)
    local rest = pkt:sub(6 + len)
    return {
        type = msg_type,
        len = len,
        payload = payload
    }, rest
end

function proto.serialize_replicate(tx_id, origin_node, ts, sql, table_name, pk_val)
    local t_name = table_name or ""
    local pk = pk_val ~= nil and tostring(pk_val) or ""
    local ts_num = tonumber(ts) or os.time()
    return string.format("%s\n%s\n%.0f\n%s\n%s\n%s", tostring(tx_id), tostring(origin_node), ts_num, tostring(t_name), tostring(pk), tostring(sql))
end

function proto.deserialize_replicate(payload)
    if not payload then return nil end
    local tx_id, origin_node, ts_str, t_name, pk_val, sql = payload:match("^([^\n]+)\n([^\n]+)\n([^\n]+)\n([^\n]*)\n([^\n]*)\n(.*)$")
    if tx_id then
        return {
            tx_id = tx_id,
            origin_node = origin_node,
            timestamp = tonumber(ts_str) or 0,
            table_name = t_name ~= "" and t_name or nil,
            pk_val = pk_val ~= "" and pk_val or nil,
            sql = sql
        }
    end
    -- Fallback for legacy 4-line format
    local l_tx, l_node, l_ts, l_sql = payload:match("^([^\n]+)\n([^\n]+)\n(%d+)\n(.*)$")
    if l_tx then
        return {
            tx_id = l_tx,
            origin_node = l_node,
            timestamp = tonumber(l_ts) or 0,
            table_name = nil,
            pk_val = nil,
            sql = l_sql
        }
    end
    return nil
end

return proto
