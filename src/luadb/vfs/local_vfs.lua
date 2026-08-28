local LocalVFS = {}
LocalVFS.__index = LocalVFS

function LocalVFS.new(config)
    local self = setmetatable({}, LocalVFS)
    self.base_dir = config and config.base_dir or "."
    return self
end

function LocalVFS:open(filename, mode)
    mode = mode or "r+b"
    local full_path = self.base_dir .. "/" .. filename
    local handle, err = io.open(full_path, mode)
    if not handle and (mode == "r+b" or mode == "rb") then
        -- Try creating if it doesn't exist
        handle, err = io.open(full_path, "w+b")
    end
    if not handle then
        return nil, "Failed to open file " .. full_path .. ": " .. tostring(err)
    end

    local file_obj = {
        handle = handle,
        path = full_path,
        vfs = self
    }

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
        self.handle:flush()
        return true
    end

    function file_obj:close()
        if self.handle then
            self.handle:close()
            self.handle = nil
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
    return os.remove(full_path)
end

return LocalVFS
