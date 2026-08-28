local serializer = require("luadb.storage.serializer")

local page_mgr = {}

page_mgr.PAGE_SIZE = 4096
page_mgr.PAGE_TYPE_HEADER = 1
page_mgr.PAGE_TYPE_LEAF = 2
page_mgr.PAGE_TYPE_INTERIOR = 3

-- Create a new blank page buffer
function page_mgr.new_page(page_type, next_page_id)
    page_type = page_type or page_mgr.PAGE_TYPE_LEAF
    next_page_id = next_page_id or 0
    local header = string.char(page_type) .. serializer.pack_uint32(0) .. serializer.pack_uint32(next_page_id)
    local padding = string.rep("\0", page_mgr.PAGE_SIZE - #header)
    return header .. padding
end

-- Read page header
function page_mgr.get_type(page_data)
    if not page_data or #page_data < 1 then return nil end
    return string.byte(page_data, 1, 1)
end

function page_mgr.get_count(page_data)
    if not page_data or #page_data < 5 then return 0 end
    local count = serializer.unpack_uint32(page_data, 2)
    return count or 0
end

function page_mgr.get_next_page(page_data)
    if not page_data or #page_data < 9 then return 0 end
    return serializer.unpack_uint32(page_data, 6) or 0
end

-- Write page header count
function page_mgr.set_count(page_data, count)
    local prefix = page_data:sub(1, 1) .. serializer.pack_uint32(count) .. page_data:sub(6, 9)
    return prefix .. page_data:sub(10)
end

-- Read items from leaf page
function page_mgr.read_items(page_data)
    local count = page_mgr.get_count(page_data)
    local items = {}
    local pos = 10 -- items start after 9-byte header (1 type + 4 count + 4 next_page_id)

    for i = 1, count do
        if pos > #page_data then break end
        local tag = string.byte(page_data, pos, pos)
        if not tag or tag == 0 then break end

        local key, next_pos = serializer.unpack_value(page_data, pos)
        if key == nil then break end
        local row
        row, next_pos = serializer.unpack_row(page_data, next_pos)
        table.insert(items, { key = key, row = row })
        pos = next_pos
    end
    return items
end

function page_mgr.can_fit(items)
    local size = 9 -- header size
    for i = 1, #items do
        local key_str = serializer.pack_value(items[i].key)
        local row_str = serializer.pack_row(items[i].row)
        size = size + #key_str + #row_str
    end
    return size <= page_mgr.PAGE_SIZE
end

-- Write items to leaf page
function page_mgr.write_items(page_data, items, next_page_id)
    local page_type = page_mgr.get_type(page_data) or page_mgr.PAGE_TYPE_LEAF
    local next_id = next_page_id or page_mgr.get_next_page(page_data)
    local parts = { string.char(page_type), serializer.pack_uint32(#items), serializer.pack_uint32(next_id) }
    for i = 1, #items do
        table.insert(parts, serializer.pack_value(items[i].key))
        table.insert(parts, serializer.pack_row(items[i].row))
    end
    local body = table.concat(parts)
    if #body > page_mgr.PAGE_SIZE then
        error("Page payload overflow: " .. #body .. " > " .. page_mgr.PAGE_SIZE)
    end
    local padding = string.rep("\0", page_mgr.PAGE_SIZE - #body)
    return body .. padding
end

-- Read interior page (key -> child_page_id mappings)
function page_mgr.read_interior(page_data)
    local count = page_mgr.get_count(page_data)
    local keys = {}
    local children = {}
    local right_child, pos = serializer.unpack_uint32(page_data, 6)
    pos = pos or 10

    for i = 1, count do
        local key, child_id
        key, pos = serializer.unpack_value(page_data, pos)
        child_id, pos = serializer.unpack_uint32(page_data, pos)
        if not key then break end
        table.insert(keys, key)
        table.insert(children, child_id or 0)
    end
    return keys, children, right_child or 0
end

-- Write interior page
function page_mgr.write_interior(page_data, keys, children, right_child)
    local page_type = page_mgr.PAGE_TYPE_INTERIOR
    local parts = { string.char(page_type), serializer.pack_uint32(#keys), serializer.pack_uint32(right_child or 0) }
    for i = 1, #keys do
        table.insert(parts, serializer.pack_value(keys[i]))
        table.insert(parts, serializer.pack_uint32(children[i] or 0))
    end
    local body = table.concat(parts)
    if #body > page_mgr.PAGE_SIZE then
        error("Interior Page payload overflow: " .. #body .. " > " .. page_mgr.PAGE_SIZE)
    end
    local padding = string.rep("\0", page_mgr.PAGE_SIZE - #body)
    return body .. padding
end

return page_mgr
