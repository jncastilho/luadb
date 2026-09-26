local vfs_factory = require("europadb.vfs")
local WAL = require("europadb.storage.wal")
local parser = require("europadb.sql.parser")
local Executor = require("europadb.sql.executor")
local scheduler = require("europadb.async.scheduler")

local europadb = {
    _VERSION = "2.0.0-europa",
    _HERITAGE = "LuaDB"
}
local luadb = europadb

function europadb.open(config)
    config = config or {}
    local driver_type = config.driver or "local"
    local storage_path = config.storage_path or "europadb.db"

    local vfs = vfs_factory.create(driver_type, config.s3 or config)
    local file_obj, err = vfs:open(storage_path, "r+b", config)
    if not file_obj then
        error("EuropaDB failed to open storage: " .. tostring(err))
    end

    local wal = WAL.new(file_obj, vfs, storage_path)
    local exec = Executor.new(wal)

    local db = {
        vfs = vfs,
        file = file_obj,
        wal = wal,
        executor = exec
    }

    local replicator_mod = require("europadb.cluster.replicator")
    local rep = replicator_mod.new(db, {
        nodes = config.nodes,
        nodes_env = config.nodes_env,
        node_id = config.node_id,
        ttl_seconds = config.ttl_seconds
    })
    db.replicator = rep
    exec.replicator = rep
    function db:exec(sql, params)
        local ast, parse_err = parser.parse(sql, params)
        if not ast then
            return nil, parse_err
        end
        local res, err = self.executor:execute(ast)
        if res and self.replicator and not self.replicator.is_replicating then
            self.replicator:broadcast(sql, nil, res)
        end
        return res, err
    end

    -- Automatically restore persisted replication conflict versions across restarts
    rep:load_persistent_state()

    -- Streaming Coroutine Cursor Iterator
    function db:cursor(sql, params)
        local rows, err = self:exec(sql, params)
        if not rows or type(rows) ~= "table" then
            return function() return nil end
        end

        local co = coroutine.create(function()
            for _, row in ipairs(rows) do
                coroutine.yield(row)
            end
        end)

        return function()
            if coroutine.status(co) == "dead" then return nil end
            local ok, row = coroutine.resume(co)
            if ok then return row else return nil end
        end
    end

    -- Non-blocking Async Coroutine Execution
    function db:exec_async(sql, params, callback)
        local db_self = self
        local co = coroutine.create(function()
            local res, err = db_self:exec(sql, params)
            if callback then callback(res, err) end
        end)
        coroutine.resume(co)
        return co
    end

    function db:prepare(sql)
        local db_self = self
        return {
            exec = function(self_stmt, ...)
                local params = { ... }
                return db_self:exec(sql, params)
            end,
            cursor = function(self_stmt, ...)
                local params = { ... }
                return db_self:cursor(sql, params)
            end
        }
    end

    function db:begin()
        return self:exec("BEGIN TRANSACTION;")
    end

    function db:commit()
        if self.replicator then
            self.replicator:flush_tx_pending()
        end
        return self:exec("COMMIT;")
    end

    function db:rollback()
        if self.replicator then
            self.replicator:discard_tx_pending()
        end
        return self:exec("ROLLBACK;")
    end

    function db:recover()
        return self.wal:recover()
    end

    function db:gc()
        collectgarbage("collect")
        return collectgarbage("count")
    end

    function db:checkpoint()
        return self.wal:checkpoint()
    end

    function db:close()
        if self.replicator then
            self.replicator:persist_state()
        end
        self.wal:close()
        if self.file then
            self.file:close()
            self.file = nil
        end
        return true
    end

    return db
end

-- Parallel Connection Pool Factory
function europadb.pool(size, config)
    return scheduler.create_pool(size, config)
end

-- Backwards compatibility searcher: intercepts require("luadb...") and require("europa...")
local searchers = package.loaders or package.searchers
if searchers and not _G._EUROPADB_LOADER_REGISTERED then
    _G._EUROPADB_LOADER_REGISTERED = true
    table.insert(searchers, 1, function(modname)
        if modname == "luadb" or modname == "europa" then
            return function() return require("europadb") end
        elseif modname:sub(1, 6) == "luadb." then
            local redirected = "europadb." .. modname:sub(7)
            return function() return require(redirected) end
        elseif modname:sub(1, 7) == "europa." then
            local redirected = "europadb." .. modname:sub(8)
            return function() return require(redirected) end
        end
        return nil
    end)
end

return europadb
