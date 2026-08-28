local scheduler = {}
scheduler.__index = scheduler

function scheduler.new()
    local self = setmetatable({}, scheduler)
    self.tasks = {}
    return self
end

function scheduler:spawn(func, ...)
    local args = { ... }
    local co = coroutine.create(function()
        return func((unpack or table.unpack)(args))
    end)
    table.insert(self.tasks, co)
    return co
end

function scheduler:step()
    local next_tasks = {}
    local completed = 0

    for _, co in ipairs(self.tasks) do
        if coroutine.status(co) ~= "dead" then
            local ok, err = coroutine.resume(co)
            if not ok then
                print("Coroutine Execution Error: " .. tostring(err))
            end
            if coroutine.status(co) ~= "dead" then
                table.insert(next_tasks, co)
            else
                completed = completed + 1
            end
        end
    end

    self.tasks = next_tasks
    return #self.tasks, completed
end

function scheduler:run_all()
    while #self.tasks > 0 do
        self:step()
    end
end

-- Connection Pool with parallel coroutine scheduling
local pool = {}
pool.__index = pool

function scheduler.create_pool(size, config)
    local luadb = require("luadb")
    local self = setmetatable({}, pool)
    self.size = size or 4
    self.connections = {}
    self.sched = scheduler.new()

    for i = 1, self.size do
        table.insert(self.connections, luadb.open(config))
    end

    return self
end

function pool:exec_parallel(sql_list)
    local results = {}
    local total = #sql_list

    for i, sql in ipairs(sql_list) do
        local conn = self.connections[((i - 1) % self.size) + 1]
        self.sched:spawn(function()
            -- Yield to simulate non-blocking cooperative scheduling
            coroutine.yield()
            local res, err = conn:exec(sql)
            results[i] = { result = res, error = err }
        end)
    end

    self.sched:run_all()
    return results
end

function pool:close()
    for _, conn in ipairs(self.connections) do
        conn:close()
    end
end

return scheduler
