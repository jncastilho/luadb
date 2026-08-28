local MemoryVFS = {}
MemoryVFS.__index = MemoryVFS

function MemoryVFS.new(config)
    local self = setmetatable({}, MemoryVFS)
    self.files = {}
    return self
end

function MemoryVFS:open(filename, mode)
    if not self.files[filename] then
        self.files[filename] = ""
    end

    local file_obj = {
        name = filename,
        vfs = self
    }

    function file_obj:read(offset, length)
        local buffer = self.vfs.files[self.name] or ""
        local start_pos = offset + 1
        local end_pos = start_pos + length - 1
        if start_pos > #buffer then return "" end
        return buffer:sub(start_pos, math.min(end_pos, #buffer))
    end

    function file_obj:write(offset, data)
        local buffer = self.vfs.files[self.name] or ""
        local start_pos = offset + 1
        local prefix = buffer:sub(1, start_pos - 1)
        if #prefix < start_pos - 1 then
            prefix = prefix .. string.rep("\0", (start_pos - 1) - #prefix)
        end
        local suffix = ""
        local end_pos = start_pos + #data - 1
        if #buffer > end_pos then
            suffix = buffer:sub(end_pos + 1)
        end
        self.vfs.files[self.name] = prefix .. data .. suffix
        return true
    end

    function file_obj:size()
        local buffer = self.vfs.files[self.name] or ""
        return #buffer
    end

    function file_obj:sync()
        return true
    end

    function file_obj:close()
        return true
    end

    return file_obj
end

function MemoryVFS:exists(filename)
    return self.files[filename] ~= nil
end

function MemoryVFS:delete(filename)
    self.files[filename] = nil
    return true
end

return MemoryVFS
