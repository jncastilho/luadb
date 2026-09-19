local LocalVFS = {}
LocalVFS.__index = LocalVFS

LocalVFS._active_locks = setmetatable({}, { __mode = "v" })

local has_ffi, ffi = pcall(require, "ffi")
if has_ffi then
    pcall(function()
        ffi.cdef[[
            int fileno(void *stream);
            int fsync(int fd);
        ]]
    end)
end

local function _get_pid()
    local f = io.open("/proc/self/stat", "r")
    if f then
        local content = f:read("*a")
        f:close()
        local pid = tonumber(content:match("^(%d+)"))
        if pid then return pid end
    end
    return 1000
end

local function _is_pid_alive(pid)
    if not pid or pid == 0 then return false end
    local f = io.open("/proc/" .. pid .. "/stat", "r")
    if f then
        f:close()
        return true
    end
    return false
end

function LocalVFS.new(config)
    local self = setmetatable({}, LocalVFS)
    self.base_dir = config and config.base_dir or "."
    return self
end

function LocalVFS:open(filename, mode, options)
    mode = mode or "r+b"
    local full_path = self.base_dir .. "/" .. filename
    local is_wal = filename:sub(-4) == ".wal"
    local no_lock = options and options.no_lock

    -- File Locking for primary database files
    local lock_path = full_path .. ".lock"
    local needs_lock = (not is_wal) and (not no_lock) and (mode ~= "rb")

    if needs_lock then
        -- Collect any abandoned handles before checking in-process collision
        collectgarbage("collect")
        -- 1. Check in-process lock collision
        if LocalVFS._active_locks[full_path] then
            return nil, "database is locked (busy: concurrent connection in same process)"
        end

        -- 2. Check inter-process lockfile
        local lf = io.open(lock_path, "r")
        if lf then
            local raw = lf:read("*a")
            lf:close()
            local owner_pid = tonumber(raw:match("^(%d+)"))
            local my_pid = _get_pid()
            if owner_pid and owner_pid ~= my_pid and _is_pid_alive(owner_pid) then
                return nil, string.format("database is locked (busy: held by process %d)", owner_pid)
            else
                -- Stale lock from crashed process or same process re-opening
                os.remove(lock_path)
            end
        end

        -- 3. Acquire lockfile
        local out_lf, lerr = io.open(lock_path, "w")
        if out_lf then
            out_lf:write(tostring(_get_pid()) .. "\n")
            out_lf:flush()
            out_lf:close()
        end
    end

    local handle, err = io.open(full_path, mode)
    if not handle and (mode == "r+b" or mode == "rb") then
        -- Try creating if it doesn't exist
        handle, err = io.open(full_path, "w+b")
    end
    if not handle then
        if needs_lock then
            os.remove(lock_path)
        end
        return nil, "Failed to open file " .. full_path .. ": " .. tostring(err)
    end

    local file_obj = setmetatable({
        handle = handle,
        path = full_path,
        lock_path = needs_lock and lock_path or nil,
        vfs = self
    }, {
        __gc = function(t)
            t:close()
        end
    })

    if needs_lock then
        LocalVFS._active_locks[full_path] = file_obj
    end

    function file_obj:read(offset, length)
        self.handle:seek("set", offset)
        local data = self.handle:read(length)
        return data or ""
    end

    function file_obj:write(offset, data)
        self.handle:seek("set", offset)
        local ok, err = self.handle:write(data)
        if not ok then return false, err end
        return true
    end

    function file_obj:size()
        local current = self.handle:seek()
        local size = self.handle:seek("end")
        self.handle:seek("set", current)
        return size
    end

    function file_obj:sync()
        if self.handle then
            self.handle:flush()
            if has_ffi and ffi.C and ffi.C.fsync and ffi.C.fileno then
                pcall(function()
                    local fd = ffi.C.fileno(self.handle)
                    if fd and fd >= 0 then
                        ffi.C.fsync(fd)
                    end
                end)
            end
        end
        return true
    end

    function file_obj:close()
        if self.handle then
            self:sync()
            self.handle:close()
            self.handle = nil
        end
        if self.lock_path then
            LocalVFS._active_locks[self.path] = nil
            os.remove(self.lock_path)
            self.lock_path = nil
        end
        return true
    end

    return file_obj
end

function LocalVFS:exists(filename)
    local full_path = self.base_dir .. "/" .. filename
    local f = io.open(full_path, "rb")
    if f then
        f:close()
        return true
    end
    return false
end

function LocalVFS:delete(filename)
    local full_path = self.base_dir .. "/" .. filename
    if LocalVFS._active_locks[full_path] then
        LocalVFS._active_locks[full_path] = nil
    end
    os.remove(full_path .. ".lock")
    os.remove(full_path .. ".wal")
    return os.remove(full_path)
end

return LocalVFS
