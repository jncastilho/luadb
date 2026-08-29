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

local function get_physical_micros()
    if ffi_ok then
        local tv = ffi.new("struct timeval")
        if ffi.C.gettimeofday(tv, nil) == 0 then
            return tonumber(tv.tv_sec) * 1000000 + tonumber(tv.tv_usec)
        end
    end
    return math.floor(os.time() * 1000000)
end

function ConflictResolver.new(node_id)
    local self = setmetatable({}, ConflictResolver)
    self.node_id = node_id or "node_local"
    self.last_pt = 0     -- Physical microsecond clock state
    self.logical_lc = 0  -- Logical counter state
    self.row_versions = {} -- table_name -> (pk_val -> { hlc_ts, node_id, pt, lc })
    self.conflict_log = {} -- Array of resolved conflict records
    return self
end

-- Update HLC state on event (local write or received remote timestamp)
-- HLC Algorithm:
--   pt' = max(last_pt, physical_now, remote_pt)
--   if pt' == last_pt == remote_pt: lc' = max(last_lc, remote_lc) + 1
--   else if pt' == last_pt:          lc' = last_lc + 1
--   else if pt' == remote_pt:        lc' = remote_lc + 1
--   else:                           lc' = 0
function ConflictResolver:update_hlc(remote_pt, remote_lc)
    local phys = get_physical_micros()
    remote_pt = tonumber(remote_pt) or 0
    remote_lc = tonumber(remote_lc) or 0

    local max_pt = math.max(self.last_pt, phys, remote_pt)

    if max_pt == self.last_pt and max_pt == remote_pt then
        self.logical_lc = math.max(self.logical_lc, remote_lc) + 1
    elseif max_pt == self.last_pt then
        self.logical_lc = self.logical_lc + 1
    elseif max_pt == remote_pt then
        self.logical_lc = remote_lc + 1
    else
        self.logical_lc = 0
    end

    self.last_pt = max_pt
    -- Encoded HLC timestamp: microsecond physical time + 3-digit logical counter
    local composite_ts = self.last_pt * 1000 + (self.logical_lc % 1000)
    return composite_ts, self.last_pt, self.logical_lc
end

function ConflictResolver.now_us(self_or_nil)
    local target = (type(self_or_nil) == "table" and self_or_nil.update_hlc) and self_or_nil or ConflictResolver.new("static")
    local composite_ts, _, _ = target:update_hlc(0, 0)
    return composite_ts
end

function ConflictResolver:get_row_version(table_name, pk_val)
    if not table_name or pk_val == nil then return nil end
    local tbl = self.row_versions[table_name:lower()]
    if not tbl then return nil end
    return tbl[tostring(pk_val)]
end

function ConflictResolver:set_row_version(table_name, pk_val, hlc_ts, node_id, pt, lc)
    if not table_name or pk_val == nil then return end
    local t_name = table_name:lower()
    if not self.row_versions[t_name] then
        self.row_versions[t_name] = {}
    end

    local ts_num = tonumber(hlc_ts)
    if not ts_num then
        ts_num, pt, lc = self:update_hlc(pt, lc)
    end

    self.row_versions[t_name][tostring(pk_val)] = {
        hlc_ts = ts_num,
        node_id = node_id or self.node_id,
        pt = pt or math.floor(ts_num / 1000),
        lc = lc or (ts_num % 1000)
    }
end

-- Last-Write-Wins (LWW) with Node-ID Deterministic Tie-Breaking
-- Updates local HLC clock upon receiving remote timestamp (HLC advance guarantee)
function ConflictResolver:should_apply(table_name, pk_val, incoming_ts, incoming_node_id, incoming_pt, incoming_lc)
    incoming_ts = tonumber(incoming_ts) or 0
    incoming_node_id = tostring(incoming_node_id or "")

    -- Extract pt and lc if passed or compute from composite incoming_ts
    if not incoming_pt then incoming_pt = math.floor(incoming_ts / 1000) end
    if not incoming_lc then incoming_lc = incoming_ts % 1000 end

    -- Advance local HLC state to at least the observed incoming timestamp
    self:update_hlc(incoming_pt, incoming_lc)

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
        resolved_at = self:now_us()
    })
end

-- Export row version state for persistent storage (e.g. WAL catalog / system tables)
function ConflictResolver:export_state()
    return {
        last_pt = self.last_pt,
        logical_lc = self.logical_lc,
        row_versions = self.row_versions
    }
end

-- Import row version state from persistent storage
function ConflictResolver:import_state(state)
    if not state or type(state) ~= "table" then return end
    self.last_pt = math.max(self.last_pt, state.last_pt or 0)
    self.logical_lc = math.max(self.logical_lc, state.logical_lc or 0)
    if state.row_versions then
        for t_name, rows in pairs(state.row_versions) do
            if not self.row_versions[t_name] then self.row_versions[t_name] = {} end
            for pk, ver in pairs(rows) do
                self.row_versions[t_name][pk] = {
                    hlc_ts = ver.hlc_ts,
                    node_id = ver.node_id,
                    pt = ver.pt,
                    lc = ver.lc
                }
            end
        end
    end
end

return ConflictResolver
