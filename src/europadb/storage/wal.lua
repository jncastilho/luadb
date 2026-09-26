local serializer = require("europadb.storage.serializer")

local WAL = {}
WAL.__index = WAL

WAL.MAGIC = "LUAWAL01"
WAL.HEADER_SIZE = 32
WAL.FRAME_HEADER_SIZE = 16
WAL.PAGE_SIZE = 4096
WAL.FRAME_SIZE = 4112 -- 16 bytes header + 4096 bytes data
WAL.AUTO_CHECKPOINT_FRAMES = 1000

local function adler32(data)
    local a = 1
    local b = 0
    local mod = 65521
    local len = #data
    for i = 1, len do
        a = (a + string.byte(data, i)) % mod
        b = (b + a) % mod
    end
    return (b * 65536) + a
end

function WAL.new(vfs_file, vfs, storage_path)
    local self = setmetatable({}, WAL)
    self.file = vfs_file
    self.vfs = vfs
    self.storage_path = storage_path
    self.pending_pages = {} -- uncommitted page mutations in current transaction
    self.wal_index = {}     -- committed page mutations awaiting checkpoint { [page_id] = page_data }
    self.in_transaction = false
    self.tx_id = 0
    self.auto_checkpoint_frames = WAL.AUTO_CHECKPOINT_FRAMES

    self.wal_frame_index = {} -- [page_id] = wal_file_byte_offset
    self.wal_indexed_size = WAL.HEADER_SIZE

    if self.vfs and self.storage_path then
        local wal_name = self.storage_path .. ".wal"
        local ok, wf = pcall(function()
            return self.vfs:open(wal_name, "r+b", { no_lock = true })
        end)
        if ok and wf then
            self.wal_file = wf
        end
    end

    -- Run recovery on open
    self:recover()

    return self
end

function WAL:begin()
    self.in_transaction = true
    self.tx_id = self.tx_id + 1
    self.pending_pages = {}
end

function WAL:write_page(page_id, page_data)
    if self.in_transaction then
        self.pending_pages[page_id] = page_data
    else
        self:begin()
        self.pending_pages[page_id] = page_data
        self:commit()
    end
end

function WAL:sync_wal_index()
    if not self.wal_file then return end
    local current_size = self.wal_file:size()
    if current_size < self.wal_indexed_size then
        -- Checkpoint occurred and truncated/reset the WAL file
        self.wal_frame_index = {}
        self.wal_indexed_size = WAL.HEADER_SIZE
    end
    if current_size >= self.wal_indexed_size + WAL.FRAME_SIZE then
        local offset = self.wal_indexed_size
        while offset + WAL.FRAME_SIZE <= current_size do
            local frame_data = self.wal_file:read(offset, WAL.FRAME_SIZE)
            if not frame_data or #frame_data < WAL.FRAME_SIZE then break end

            local page_id = serializer.unpack_uint32(frame_data, 1)
            local commit_flag = serializer.unpack_uint32(frame_data, 5)
            local tx_id = serializer.unpack_uint32(frame_data, 9)
            local stored_cksum = serializer.unpack_uint32(frame_data, 13)
            local page_payload = frame_data:sub(17, 16 + WAL.PAGE_SIZE)

            local payload = serializer.pack_uint32(page_id) ..
                            serializer.pack_uint32(commit_flag) ..
                            serializer.pack_uint32(tx_id) ..
                            page_payload
            if adler32(payload) == stored_cksum then
                self.wal_frame_index[page_id] = offset
            else
                break
            end
            offset = offset + WAL.FRAME_SIZE
        end
        self.wal_indexed_size = offset
    end
end

function WAL:read_wal_frame(target_page_id)
    if not self.wal_file then return nil end
    self:sync_wal_index()
    local offset = self.wal_frame_index[target_page_id]
    if not offset then return nil end

    local frame_data = self.wal_file:read(offset, WAL.FRAME_SIZE)
    if frame_data and #frame_data == WAL.FRAME_SIZE then
        local page_id = serializer.unpack_uint32(frame_data, 1)
        if page_id == target_page_id then
            local commit_flag = serializer.unpack_uint32(frame_data, 5)
            local tx_id = serializer.unpack_uint32(frame_data, 9)
            local stored_cksum = serializer.unpack_uint32(frame_data, 13)
            local page_payload = frame_data:sub(17, 16 + WAL.PAGE_SIZE)

            local payload = serializer.pack_uint32(page_id) ..
                            serializer.pack_uint32(commit_flag) ..
                            serializer.pack_uint32(tx_id) ..
                            page_payload
            if adler32(payload) == stored_cksum then
                return page_payload
            end
        end
    end
    return nil
end

function WAL:read_page(page_id)
    -- 1. Check in-flight uncommitted transaction mutations
    if self.pending_pages[page_id] then
        return self.pending_pages[page_id]
    end
    -- 2. Check committed WAL index (pages committed to WAL but not yet checkpointed)
    if self.wal_index[page_id] then
        return self.wal_index[page_id]
    end
    -- 3. Check on-disk WAL for committed frames from sibling connections
    if self.wal_file then
        local p = self:read_wal_frame(page_id)
        if p then return p end
    end
    -- 4. Read from main database file
    local offset = (page_id - 1) * WAL.PAGE_SIZE
    local data = self.file:read(offset, WAL.PAGE_SIZE)
    if not data or #data == 0 then
        return nil
    end
    return data
end

function WAL:commit()
    if not self.in_transaction then return true end

    -- Gather list of page_ids to write
    local page_list = {}
    for page_id, _ in pairs(self.pending_pages) do
        table.insert(page_list, page_id)
    end

    if #page_list == 0 then
        self.in_transaction = false
        return true
    end

    -- If on-disk WAL file is available, append frames sequentially
    if self.wal_file then
        if self.wal_file:size() == 0 then
            -- Write WAL Header (32 bytes)
            local hdr = WAL.MAGIC ..
                        serializer.pack_uint32(WAL.PAGE_SIZE) ..
                        serializer.pack_uint32(1) .. -- version 1
                        serializer.pack_uint32(12345) .. -- salt
                        serializer.pack_uint32(0) .. -- reserved
                        string.rep("\0", 8)
            self.wal_file:write(0, hdr)
        end

        for idx, page_id in ipairs(page_list) do
            local page_data = self.pending_pages[page_id]
            -- Last frame in the transaction has commit_flag = 1
            local commit_flag = (idx == #page_list) and 1 or 0
            local payload = serializer.pack_uint32(page_id) ..
                            serializer.pack_uint32(commit_flag) ..
                            serializer.pack_uint32(self.tx_id) ..
                            page_data
            local cksum = adler32(payload)
            local frame_hdr = serializer.pack_uint32(page_id) ..
                              serializer.pack_uint32(commit_flag) ..
                              serializer.pack_uint32(self.tx_id) ..
                              serializer.pack_uint32(cksum)
            local frame = frame_hdr .. page_data
            local wal_offset = self.wal_file:size()
            self.wal_file:write(wal_offset, frame)
            self.wal_frame_index[page_id] = wal_offset
        end
        self.wal_indexed_size = self.wal_file:size()
        self.wal_file:sync()
    end

    -- Update committed WAL index
    for page_id, page_data in pairs(self.pending_pages) do
        self.wal_index[page_id] = page_data
        -- If no separate wal_file, write straight to main file
        if not self.wal_file then
            local offset = (page_id - 1) * WAL.PAGE_SIZE
            self.file:write(offset, page_data)
        end
    end

    if not self.wal_file then
        self.file:sync()
    end

    self.pending_pages = {}
    self.in_transaction = false

    -- Auto-checkpoint when WAL exceeds threshold (default 1,000 frames)
    if self.wal_file and self.auto_checkpoint_frames and self.auto_checkpoint_frames > 0 then
        local threshold_size = WAL.HEADER_SIZE + (self.auto_checkpoint_frames * WAL.FRAME_SIZE)
        if self.wal_file:size() >= threshold_size then
            self:checkpoint()
        end
    end

    return true
end

function WAL:rollback()
    self.pending_pages = {}
    self.in_transaction = false
    return true
end

function WAL:checkpoint()
    -- Replay all committed pages in WAL index into main database file
    for page_id, page_data in pairs(self.wal_index) do
        local offset = (page_id - 1) * WAL.PAGE_SIZE
        self.file:write(offset, page_data)
    end
    self.file:sync()
    self.wal_index = {}
    self.wal_frame_index = {}
    self.wal_indexed_size = WAL.HEADER_SIZE

    -- Reset on-disk WAL file
    if self.wal_file then
        local hdr = WAL.MAGIC ..
                    serializer.pack_uint32(WAL.PAGE_SIZE) ..
                    serializer.pack_uint32(1) ..
                    serializer.pack_uint32(12345) ..
                    serializer.pack_uint32(0) ..
                    string.rep("\0", 8)
        self.wal_file:write(0, hdr)
        self.wal_file:sync()
        if self.vfs and self.storage_path and self.vfs.delete then
            self.wal_file:close()
            local wal_name = self.storage_path .. ".wal"
            self.vfs:delete(wal_name)
            self.wal_file = self.vfs:open(wal_name, "w+b", { no_lock = true })
        end
    end
    return true
end

function WAL:recover()
    self.pending_pages = {}
    self.in_transaction = false

    if not self.wal_file then
        if self.file and self.file.sync then
            pcall(function() self.file:sync() end)
        end
        return true
    end

    local wal_size = self.wal_file:size()
    if wal_size < WAL.HEADER_SIZE + WAL.FRAME_SIZE then
        return true
    end

    local hdr_bytes = self.wal_file:read(0, WAL.HEADER_SIZE)
    if not hdr_bytes or hdr_bytes:sub(1, 8) ~= WAL.MAGIC then
        return false, "Corrupted WAL header magic"
    end

    -- Scan frames
    local offset = WAL.HEADER_SIZE
    local cur_tx_frames = {}
    local current_tx_id = nil

    while offset + WAL.FRAME_SIZE <= wal_size do
        local frame_data = self.wal_file:read(offset, WAL.FRAME_SIZE)
        if not frame_data or #frame_data < WAL.FRAME_SIZE then
            break
        end

        local page_id = serializer.unpack_uint32(frame_data, 1)
        local commit_flag = serializer.unpack_uint32(frame_data, 5)
        local tx_id = serializer.unpack_uint32(frame_data, 9)
        local stored_cksum = serializer.unpack_uint32(frame_data, 13)
        local page_payload = frame_data:sub(17, 16 + WAL.PAGE_SIZE)

        -- Checksum verification
        local payload_for_cksum = serializer.pack_uint32(page_id) ..
                                  serializer.pack_uint32(commit_flag) ..
                                  serializer.pack_uint32(tx_id) ..
                                  page_payload
        local calc_cksum = adler32(payload_for_cksum)

        if calc_cksum ~= stored_cksum then
            -- Torn write or corrupted frame: halt recovery at last valid commit
            break
        end

        if current_tx_id ~= tx_id then
            cur_tx_frames = {}
            current_tx_id = tx_id
        end

        table.insert(cur_tx_frames, { page_id = page_id, data = page_payload })

        if commit_flag == 1 then
            -- Transaction fully committed on disk: record all its frames
            for _, f in ipairs(cur_tx_frames) do
                self.wal_index[f.page_id] = f.data
            end
            cur_tx_frames = {}
        end

        offset = offset + WAL.FRAME_SIZE
    end

    -- Replay committed pages into main file and checkpoint
    self:checkpoint()
    return true
end

function WAL:close()
    self:checkpoint()
    if self.wal_file then
        self.wal_file:close()
        self.wal_file = nil
    end
end

return WAL
