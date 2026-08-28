local serializer = require("luadb.storage.serializer")

local WAL = {}
WAL.__index = WAL

function WAL.new(vfs_file)
    local self = setmetatable({}, WAL)
    self.file = vfs_file
    self.pending_pages = {} -- uncommitted page mutations
    self.in_transaction = false
    return self
end

function WAL:begin()
    self.in_transaction = true
    self.pending_pages = {}
end

function WAL:write_page(page_id, page_data)
    if self.in_transaction then
        self.pending_pages[page_id] = page_data
    else
        local offset = (page_id - 1) * 4096
        self.file:write(offset, page_data)
    end
end

function WAL:read_page(page_id)
    if self.pending_pages[page_id] then
        return self.pending_pages[page_id]
    end
    local offset = (page_id - 1) * 4096
    local data = self.file:read(offset, 4096)
    if not data or #data == 0 then
        return nil
    end
    return data
end

function WAL:commit()
    if not self.in_transaction then return true end
    for page_id, page_data in pairs(self.pending_pages) do
        local offset = (page_id - 1) * 4096
        self.file:write(offset, page_data)
    end
    self.file:sync()
    self.pending_pages = {}
    self.in_transaction = false
    return true
end

function WAL:rollback()
    self.pending_pages = {}
    self.in_transaction = false
    return true
end

function WAL:recover()
    -- Reset transient uncommitted pages and flush VFS storage handles
    self.pending_pages = {}
    self.in_transaction = false
    if self.file and self.file.sync then
        pcall(function() self.file:sync() end)
    end
    return true
end

return WAL
