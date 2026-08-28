local page_mgr = require("luadb.storage.page")

local BTree = {}
BTree.__index = BTree

function BTree.new(wal, root_page_id, page_allocator)
    local self = setmetatable({}, BTree)
    self.wal = wal
    self.root_page_id = root_page_id or 1
    self.allocator = page_allocator

    -- Ensure root page exists
    local root_data = self.wal:read_page(self.root_page_id)
    if not root_data or #root_data < 4096 then
        root_data = page_mgr.new_page(page_mgr.PAGE_TYPE_LEAF)
        self.wal:write_page(self.root_page_id, root_data)
    end

    return self
end

function BTree:_allocate_page()
    if self.allocator then
        return self.allocator()
    end
    local file_size = 0
    if self.wal and self.wal.file and self.wal.file.size then
        local ok, s = pcall(function() return self.wal.file:size() end)
        if ok and s then file_size = s end
    end
    local next_id = math.floor(file_size / 4096) + 1
    if next_id <= self.root_page_id then next_id = self.root_page_id + 1 end
    return next_id
end

function BTree:insert(key, row)
    local split_key, new_child_id = self:_insert_into_node(self.root_page_id, key, row)
    if split_key then
        local old_root = self:_allocate_page()
        local root_data = self.wal:read_page(self.root_page_id)
        self.wal:write_page(old_root, root_data)

        local new_root = page_mgr.write_interior(
            page_mgr.new_page(page_mgr.PAGE_TYPE_INTERIOR),
            { split_key },
            { old_root },
            new_child_id
        )
        self.wal:write_page(self.root_page_id, new_root)
    end
    return true
end

local function safe_cmp(a, b)
    if a == b then return 0 end
    if a == nil then return -1 end
    if b == nil then return 1 end
    if type(a) ~= type(b) then
        a = tostring(a)
        b = tostring(b)
    end
    if a < b then return -1
    elseif a > b then return 1
    else return 0 end
end

function BTree:_insert_into_node(page_id, key, row)
    local page_data = self.wal:read_page(page_id)
    local page_type = page_mgr.get_type(page_data)

    if page_type == page_mgr.PAGE_TYPE_LEAF then
        local items = page_mgr.read_items(page_data)
        local inserted = false
        for i = 1, #items do
            local cmp = safe_cmp(items[i].key, key)
            if cmp == 0 then
                items[i].row = row
                inserted = true
                break
            elseif cmp > 0 then
                table.insert(items, i, { key = key, row = row })
                inserted = true
                break
            end
        end
        if not inserted then
            table.insert(items, { key = key, row = row })
        end

        if page_mgr.can_fit(items) then
            local updated_page = page_mgr.write_items(page_data, items)
            self.wal:write_page(page_id, updated_page)
            return nil, nil
        else
            -- Leaf Split
            local mid = math.floor(#items / 2)
            local items1 = {}
            local items2 = {}
            for i = 1, mid do table.insert(items1, items[i]) end
            for i = mid + 1, #items do table.insert(items2, items[i]) end

            local new_page_id = self:_allocate_page()
            local p1 = page_mgr.write_items(page_mgr.new_page(page_mgr.PAGE_TYPE_LEAF), items1)
            local p2 = page_mgr.write_items(page_mgr.new_page(page_mgr.PAGE_TYPE_LEAF), items2)

            self.wal:write_page(page_id, p1)
            self.wal:write_page(new_page_id, p2)

            return items2[1].key, new_page_id
        end

    elseif page_type == page_mgr.PAGE_TYPE_INTERIOR then
        local keys, children, right_child = page_mgr.read_interior(page_data)
        local target_child = right_child
        local target_idx = #keys + 1

        for i = 1, #keys do
            if safe_cmp(key, keys[i]) < 0 then
                target_child = children[i]
                target_idx = i
                break
            end
        end

        local split_key, new_child_id = self:_insert_into_node(target_child, key, row)
        if split_key then
            if target_idx <= #keys then
                table.insert(keys, target_idx, split_key)
                table.insert(children, target_idx + 1, new_child_id)
            else
                table.insert(keys, split_key)
                table.insert(children, right_child)
                right_child = new_child_id
            end

            local test_page = page_mgr.write_interior(page_mgr.new_page(page_mgr.PAGE_TYPE_INTERIOR), keys, children, right_child)
            if #test_page <= page_mgr.PAGE_SIZE then
                self.wal:write_page(page_id, test_page)
                return nil, nil
            else
                local mid = math.floor(#keys / 2)
                local promoted_key = keys[mid]
                local k1, c1 = {}, {}
                local k2, c2 = {}, {}
                for i = 1, mid - 1 do table.insert(k1, keys[i]); table.insert(c1, children[i]) end
                local right1 = children[mid]
                for i = mid + 1, #keys do table.insert(k2, keys[i]); table.insert(c2, children[i]) end
                local right2 = right_child

                local new_int_id = self:_allocate_page()
                local p1 = page_mgr.write_interior(page_mgr.new_page(page_mgr.PAGE_TYPE_INTERIOR), k1, c1, right1)
                local p2 = page_mgr.write_interior(page_mgr.new_page(page_mgr.PAGE_TYPE_INTERIOR), k2, c2, right2)

                self.wal:write_page(page_id, p1)
                self.wal:write_page(new_int_id, p2)
                return promoted_key, new_int_id
            end
        end
    end

    return nil, nil
end

function BTree:find(key)
    return self:_find_in_node(self.root_page_id, key)
end

function BTree:_find_in_node(page_id, key)
    local page_data = self.wal:read_page(page_id)
    if not page_data then return nil end
    local page_type = page_mgr.get_type(page_data)

    if page_type == page_mgr.PAGE_TYPE_LEAF then
        local items = page_mgr.read_items(page_data)
        for i = 1, #items do
            if safe_cmp(items[i].key, key) == 0 then
                return items[i].row
            end
        end
    elseif page_type == page_mgr.PAGE_TYPE_INTERIOR then
        local keys, children, right_child = page_mgr.read_interior(page_data)
        local target_child = right_child
        for i = 1, #keys do
            if safe_cmp(key, keys[i]) < 0 then
                target_child = children[i]
                break
            end
        end
        return self:_find_in_node(target_child, key)
    end
    return nil
end

function BTree:scan(predicate)
    local results = {}
    self:_scan_node(self.root_page_id, predicate, results)
    return results
end

function BTree:_scan_node(page_id, predicate, results)
    local page_data = self.wal:read_page(page_id)
    if not page_data then return end
    local page_type = page_mgr.get_type(page_data)

    if page_type == page_mgr.PAGE_TYPE_LEAF then
        local items = page_mgr.read_items(page_data)
        for i = 1, #items do
            if not predicate or predicate(items[i].row, items[i].key) then
                table.insert(results, items[i].row)
            end
        end
    elseif page_type == page_mgr.PAGE_TYPE_INTERIOR then
        local keys, children, right_child = page_mgr.read_interior(page_data)
        for _, child_id in ipairs(children) do
            self:_scan_node(child_id, predicate, results)
        end
        if right_child and right_child > 0 then
            self:_scan_node(right_child, predicate, results)
        end
    end
end

function BTree:scan_items(predicate)
    local results = {}
    self:_scan_items_node(self.root_page_id, predicate, results)
    return results
end

function BTree:_scan_items_node(page_id, predicate, results)
    local page_data = self.wal:read_page(page_id)
    if not page_data then return end
    local page_type = page_mgr.get_type(page_data)

    if page_type == page_mgr.PAGE_TYPE_LEAF then
        local items = page_mgr.read_items(page_data)
        for i = 1, #items do
            if not predicate or predicate(items[i].row, items[i].key) then
                table.insert(results, items[i])
            end
        end
    elseif page_type == page_mgr.PAGE_TYPE_INTERIOR then
        local keys, children, right_child = page_mgr.read_interior(page_data)
        for _, child_id in ipairs(children) do
            self:_scan_items_node(child_id, predicate, results)
        end
        if right_child and right_child > 0 then
            self:_scan_items_node(right_child, predicate, results)
        end
    end
end

function BTree:delete(key)
    return self:_delete_from_node(self.root_page_id, key)
end

function BTree:_delete_from_node(page_id, key)
    local page_data = self.wal:read_page(page_id)
    if not page_data then return false end
    local page_type = page_mgr.get_type(page_data)

    if page_type == page_mgr.PAGE_TYPE_LEAF then
        local items = page_mgr.read_items(page_data)
        local new_items = {}
        local deleted = false
        for i = 1, #items do
            if safe_cmp(items[i].key, key) == 0 then
                deleted = true
            else
                table.insert(new_items, items[i])
            end
        end
        if deleted then
            local updated_page = page_mgr.write_items(page_data, new_items)
            self.wal:write_page(page_id, updated_page)
            return true
        end
    elseif page_type == page_mgr.PAGE_TYPE_INTERIOR then
        local keys, children, right_child = page_mgr.read_interior(page_data)
        local target_child = right_child
        for i = 1, #keys do
            if safe_cmp(key, keys[i]) < 0 then
                target_child = children[i]
                break
            end
        end
        return self:_delete_from_node(target_child, key)
    end
    return false
end

return BTree
