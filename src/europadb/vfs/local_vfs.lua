local LocalVFS = {}
LocalVFS.__index = LocalVFS

LocalVFS._active_locks = setmetatable({}, { __mode = "v" })

local has_ffi, ffi = pcall(require, "ffi")
if has_ffi then
    pcall(function()
        ffi.cdef[[
            int fileno(void *stream);
            int fsync(int fd);
            int getpid(void);
            int flock(int fd, int operation);
            int usleep(unsigned int usec);
        ]]
    end)
end

local _cached_pid = nil
local function _get_pid()
    if _cached_pid then return _cached_pid end
    if has_ffi then
        local ok, pid = pcall(function() return tonumber(ffi.C.getpid()) end)
        if ok and pid then
            _cached_pid = pid
            return pid
        end
    end
    local f = io.open("/proc/self/stat", "r")
    if f then
        local content = f:read("*a")
        f:close()
        local pid = tonumber(content:match("^(%d+)"))
        if pid then
            _cached_pid = pid
            return pid
        end
    end
    local handle = io.popen("sh -c 'echo $PPID' 2>/dev/null")
    if handle then
        local out = handle:read("*a")
        handle:close()
        local pid = tonumber(out and out:match("(%d+)"))
        if pid then
            _cached_pid = pid
            return pid
        end
    end
    _cached_pid = 1000
    return 1000
end

local function _sleep_ms(ms)
    if has_ffi and ffi.C and ffi.C.usleep then
        pcall(function() ffi.C.usleep(math.floor(ms * 1000)) end)
    else
        local t0 = os.clock()
        local target = ms / 1000
        while os.clock() - t0 < target do end
    end
end

local function _is_pid_alive(pid)
    if not pid or pid == 0 then return false end
    local f = io.open("/proc/" .. pid .. "/stat", "r")
    if f then
        f:close()
        return true
    end
    -- POSIX fallback for macOS / BSD / systems without /proc
    local ok = os.execute("kill -0 " .. pid .. " 2>/dev/null")
    return ok == 0 or ok == true
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
    local lock_handle = nil

    if needs_lock then
        local busy_timeout = (options and tonumber(options.busy_timeout)) or 0
        local start_clock = os.clock()
        local last_busy_err = nil

        while true do
            collectgarbage("collect")
            -- 1. Check in-process lock collision
            if LocalVFS._active_locks[full_path] then
                last_busy_err = "database is locked (busy: concurrent connection in same process)"
            else
                -- 2. Check inter-process lockfile
                local lf = io.open(lock_path, "r")
                local owner_pid = nil
                if lf then
                    local raw = lf:read("*a")
                    lf:close()
                    owner_pid = tonumber(raw and raw:match("^(%d+)"))
                end

                local my_pid = _get_pid()
                if owner_pid and owner_pid ~= my_pid and _is_pid_alive(owner_pid) then
                    last_busy_err = string.format("database is locked (busy: held by process %d)", owner_pid)
                else
                    if owner_pid and owner_pid ~= my_pid then
                        os.remove(lock_path)
                    end

                    -- 3. Acquire lockfile with flock
                    local out_lf = io.open(lock_path, "w+b")
                    if out_lf then
                        local flock_ok = true
                        if has_ffi and ffi.C and ffi.C.flock and ffi.C.fileno then
                            local ok, fd = pcall(function() return ffi.C.fileno(out_lf) end)
                            if ok and fd and fd >= 0 then
                                local ret = ffi.C.flock(fd, 2 + 4) -- LOCK_EX | LOCK_NB
                                if ret ~= 0 then
                                    flock_ok = false
                                end
                            end
                        end

                        if flock_ok then
                            out_lf:write(tostring(my_pid) .. "\n")
                            out_lf:flush()
                            lock_handle = out_lf
                            last_busy_err = nil
                            break
                        else
                            out_lf:close()
                            last_busy_err = "database is locked (busy: flock contention)"
                        end
                    else
                        last_busy_err = "database is locked (busy: cannot open lockfile)"
                    end
                end
            end

            local elapsed_ms = (os.clock() - start_clock) * 1000
            if elapsed_ms >= busy_timeout then
                break
            end
            _sleep_ms(math.min(25, math.max(1, busy_timeout - elapsed_ms)))
        end

        if last_busy_err then
            return nil, last_busy_err
        end
    end

    local handle, err = io.open(full_path, mode)
    if not handle and (mode == "r+b" or mode == "rb") then
        -- Try creating if it doesn't exist
        handle, err = io.open(full_path, "w+b")
    end
    if not handle then
        if lock_handle then
            lock_handle:close()
            lock_handle = nil
        end
        if needs_lock then
            os.remove(lock_path)
        end
        return nil, "Failed to open file " .. full_path .. ": " .. tostring(err)
    end

    local file_obj = setmetatable({
        handle = handle,
        path = full_path,
        lock_path = needs_lock and lock_path or nil,
        lock_handle = lock_handle,
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
        if self.lock_handle then
            self.lock_handle:close()
            self.lock_handle = nil
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
        local obj = LocalVFS._active_locks[full_path]
        if obj.lock_handle then
            obj.lock_handle:close()
            obj.lock_handle = nil
        end
        LocalVFS._active_locks[full_path] = nil
    end
    os.remove(full_path .. ".lock")
    os.remove(full_path .. ".wal")
    return os.remove(full_path)
end

return LocalVFS
