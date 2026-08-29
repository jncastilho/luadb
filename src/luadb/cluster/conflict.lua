local ffi_ok, ffi = pcall(require, "ffi")

if ffi_ok then
    pcall(ffi.cdef, [[
        typedef struct timeval {
            long tv_sec;
            long tv_usec;
        } timeval;
        int gettimeofday(struct timeval *tp, void *tzp);
    ]])
end

local ConflictResolver = {}
ConflictResolver.__index = ConflictResolver

local logical_seq = 0

function ConflictResolver.now_us()
    if ffi_ok then
        local tv = ffi.new("struct timeval")
        if ffi.C.gettimeofday(tv, nil) == 0 then
            return tonumber(tv.tv_sec) * 1000000 + tonumber(tv.tv_usec)
        end
    end
    -- Fallback for standard Lua without FFI gettimeofday
    logical_seq = (logical_seq + 1) % 1000000
    return math.floor(os.time() * 1000000) + logical_seq
end

function ConflictResolver.new(node_id)
    local self = setmetatable({}, ConflictResolver)
    self.node_id = node_id or "node_local"
    self.row_versions = {} -- table_name -> (pk_val -> { hlc_ts, node_id })
    self.conflict_log = {} -- Array of resolved conflict records
    return self
end

function ConflictResolver:get_row_version(table_name, pk_val)
    if not table_name or pk_val == nil then return nil end
    local tbl = self.row_versions[table_name:lower()]
    if not tbl then return nil end
    return tbl[tostring(pk_val)]
end

function ConflictResolver:set_row_version(table_name, pk_val, hlc_ts, node_id)
    if not table_name or pk_val == nil then return end
    local t_name = table_name:lower()
    if not self.row_versions[t_name] then
        self.row_versions[t_name] = {}
    end
    self.row_versions[t_name][tostring(pk_val)] = {
        hlc_ts = tonumber(hlc_ts) or self.now_us(),
        node_id = node_id or self.node_id
    }
end

-- Last-Write-Wins (LWW) with Node-ID Deterministic Tie-Breaking
function ConflictResolver:should_apply(table_name, pk_val, incoming_ts, incoming_node_id)
    incoming_ts = tonumber(incoming_ts) or 0
    incoming_node_id = tostring(incoming_node_id or "")

    local current = self:get_row_version(table_name, pk_val)
    if not current then
        -- No existing record version: Apply mutation
        return true, "NO_LOCAL_RECORD"
    end

    local local_ts = current.hlc_ts
    local local_node_id = current.node_id

    if incoming_ts > local_ts then
        -- Incoming mutation is strictly newer
        return true, "INCOMING_NEWER"
    elseif incoming_ts < local_ts then
        -- Local mutation is strictly newer: Reject incoming stale update
        return false, "LOCAL_NEWER"
    else
        -- Timestamp collision down to microsecond: Deterministic Node ID tie-breaking
        if incoming_node_id > local_node_id then
            return true, "TIE_BREAK_INCOMING_WINS"
        else
            return false, "TIE_BREAK_LOCAL_WINS"
        end
    end
end

function ConflictResolver:record_conflict(table_name, pk_val, winner_node, winner_ts, loser_node, loser_ts, sql, reason)
    table.insert(self.conflict_log, {
        table_name = table_name,
        pk_val = tostring(pk_val or "UNKNOWN"),
        winner_node = winner_node,
        winner_ts = tonumber(winner_ts) or 0,
        loser_node = loser_node,
        loser_ts = tonumber(loser_ts) or 0,
        sql = sql or "",
        reason = reason or "LWW",
        resolved_at = self.now_us()
    })
end

return ConflictResolver
