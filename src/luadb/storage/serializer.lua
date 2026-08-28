local serializer = {}

-- Binary packing helpers with fallback for Lua 5.1/5.2/LuaJIT
local has_pack, _ = pcall(string.pack, "i", 1)

function serializer.pack_uint32(n)
    if has_pack then
        return string.pack(">I4", n)
    end
    local b1 = math.floor(n / 16777216) % 256
    local b2 = math.floor(n / 65536) % 256
    local b3 = math.floor(n / 256) % 256
    local b4 = math.floor(n) % 256
    return string.char(b1, b2, b3, b4)
end

function serializer.unpack_uint32(str, pos)
    pos = pos or 1
    if has_pack then
        local val, next_pos = string.unpack(">I4", str, pos)
        return val, next_pos
    end
    local b1, b2, b3, b4 = string.byte(str, pos, pos + 3)
    if not b1 then return nil, pos end
    local val = b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
    return val, pos + 4
end

local ffi_ok, ffi = pcall(require, "ffi")
local double_buf, uint8_buf
if ffi_ok then
    double_buf = ffi.new("double[1]")
    uint8_buf = ffi.cast("uint8_t*", double_buf)
end

function serializer.pack_number(n)
    if has_pack then
        return string.pack(">d", n)
    elseif ffi_ok then
        double_buf[0] = n
        if ffi.abi("le") then
            return string.char(uint8_buf[7], uint8_buf[6], uint8_buf[5], uint8_buf[4],
                               uint8_buf[3], uint8_buf[2], uint8_buf[1], uint8_buf[0])
        else
            return string.char(uint8_buf[0], uint8_buf[1], uint8_buf[2], uint8_buf[3],
                               uint8_buf[4], uint8_buf[5], uint8_buf[6], uint8_buf[7])
        end
    end
    local str = tostring(n)
    return serializer.pack_uint32(#str) .. str
end

function serializer.unpack_number(str, pos)
    pos = pos or 1
    if pos + 3 <= #str then
        local b1, b2, b3, b4 = string.byte(str, pos, pos + 3)
        if b1 == 0 and b2 == 0 and b3 == 0 and b4 > 0 and b4 <= 32 and (pos + 3 + b4) <= #str then
            local cand = str:sub(pos + 4, pos + 3 + b4)
            local num = tonumber(cand)
            if num ~= nil then
                return num, pos + 4 + b4
            end
        end
    end

    if has_pack then
        local val, next_pos = string.unpack(">d", str, pos)
        return val, next_pos
    elseif ffi_ok then
        if pos + 7 > #str then return 0, pos + 8 end
        local b0, b1, b2, b3, b4, b5, b6, b7 = string.byte(str, pos, pos + 7)
        if ffi.abi("le") then
            uint8_buf[7], uint8_buf[6], uint8_buf[5], uint8_buf[4] = b0, b1, b2, b3
            uint8_buf[3], uint8_buf[2], uint8_buf[1], uint8_buf[0] = b4, b5, b6, b7
        else
            uint8_buf[0], uint8_buf[1], uint8_buf[2], uint8_buf[3] = b0, b1, b2, b3
            uint8_buf[4], uint8_buf[5], uint8_buf[6], uint8_buf[7] = b4, b5, b6, b7
        end
        return double_buf[0], pos + 8
    end
    local len, next_pos = serializer.unpack_uint32(str, pos)
    local num_str = str:sub(next_pos, next_pos + len - 1)
    return tonumber(num_str), next_pos + len
end

-- Value Type Tags:
-- 0: NULL, 1: FALSE, 2: TRUE, 3: NUMBER, 4: STRING
function serializer.pack_value(val)
    if val == nil then
        return "\x00"
    elseif val == false then
        return "\x01"
    elseif val == true then
        return "\x02"
    elseif type(val) == "number" then
        return "\x03" .. serializer.pack_number(val)
    elseif type(val) == "table" then
        local json = require("luadb.sql.json")
        local jstr = json.stringify(val)
        return "\x05" .. serializer.pack_uint32(#jstr) .. jstr
    elseif type(val) == "string" then
        if (val:sub(1,1) == "{" and val:sub(-1) == "}") or (val:sub(1,1) == "[" and val:sub(-1) == "]") then
            return "\x05" .. serializer.pack_uint32(#val) .. val
        end
        return "\x04" .. serializer.pack_uint32(#val) .. val
    else
        local str = tostring(val)
        return "\x04" .. serializer.pack_uint32(#str) .. str
    end
end

function serializer.unpack_value(str, pos)
    pos = pos or 1
    if pos > #str then return nil, pos end
    local tag = string.byte(str, pos, pos)
    pos = pos + 1
    if tag == 0 then
        return nil, pos
    elseif tag == 1 then
        return false, pos
    elseif tag == 2 then
        return true, pos
    elseif tag == 3 then
        return serializer.unpack_number(str, pos)
    elseif tag == 4 or tag == 5 then
        local len, next_pos = serializer.unpack_uint32(str, pos)
        local val = str:sub(next_pos, next_pos + len - 1)
        return val, next_pos + len
    else
        error("Unknown binary tag: " .. tostring(tag))
    end
end

function serializer.pack_row(row, explicit_count)
    local count = explicit_count or row.n or #row
    -- Calculate maximum key if there are nil holes
    if not explicit_count and not row.n then
        for k in pairs(row) do
            if type(k) == "number" and k > count then
                count = k
            end
        end
    end
    local parts = { serializer.pack_uint32(count) }
    for i = 1, count do
        table.insert(parts, serializer.pack_value(row[i]))
    end
    return table.concat(parts)
end

function serializer.unpack_row(str, pos)
    pos = pos or 1
    local count, next_pos = serializer.unpack_uint32(str, pos)
    if not count then return nil, pos end
    pos = next_pos
    local row = {}
    for i = 1, count do
        local val
        val, pos = serializer.unpack_value(str, pos)
        row[i] = val
    end
    return row, pos
end

return serializer
