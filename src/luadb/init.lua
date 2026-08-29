local vfs_factory = require("luadb.vfs")
local WAL = require("luadb.storage.wal")
local parser = require("luadb.sql.parser")
local Executor = require("luadb.sql.executor")
local scheduler = require("luadb.async.scheduler")

local luadb = {
    _VERSION = "1.1.0"
}

function luadb.open(config)
    config = config or {}
    local driver_type = config.driver or "local"
    local storage_path = config.storage_path or "luadb.db"

    local vfs = vfs_factory.create(driver_type, config.s3 or config)
    local file_obj, err = vfs:open(storage_path, "r+b")
    if not file_obj then
        error("LuaDB failed to open storage: " .. tostring(err))
    end

    local wal = WAL.new(file_obj)
    local exec = Executor.new(wal)

    local db = {
        vfs = vfs,
        file = file_obj,
        wal = wal,
        executor = exec
    }

    local replicator_mod = require("luadb.cluster.replicator")
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
            self.replicator:broadcast(sql)
        end
        return res, err
    end

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
        return self:exec("COMMIT;")
    end

    function db:rollback()
        return self:exec("ROLLBACK;")
    end

    function db:close()
        self.wal:commit()
        if self.file then
            self.file:close()
            self.file = nil
        end
        return true
    end

    return db
end

-- Parallel Connection Pool Factory
function luadb.pool(size, config)
    return scheduler.create_pool(size, config)
end

return luadb
