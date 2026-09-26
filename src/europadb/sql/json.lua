local json = {}

-- Pure Lua JSON Encoder & Decoder
local function escape_str(s)
    s = s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
    return '"' .. s .. '"'
end

function json.stringify(val)
    local t = type(val)
    if val == nil then
        return "null"
    elseif t == "boolean" then
        return val and "true" or "false"
    elseif t == "number" then
        return tostring(val)
    elseif t == "string" then
        return escape_str(val)
    elseif t == "table" then
        -- Check array: all keys must be consecutive integers 1..n
        local n = #val
        local is_array = (n > 0)
        if is_array then
            local count = 0
            for _ in pairs(val) do count = count + 1 end
            is_array = (count == n)
        end
        local parts = {}
        if is_array then
            for _, v in ipairs(val) do
                table.insert(parts, json.stringify(v))
            end
            return "[" .. table.concat(parts, ",") .. "]"
        else
            for k, v in pairs(val) do
                table.insert(parts, escape_str(tostring(k)) .. ":" .. json.stringify(v))
            end
            return "{" .. table.concat(parts, ",") .. "}"
        end
    end
    return "null"
end

function json.parse(str)
    if not str or type(str) ~= "string" or str == "" then return nil end
    local pos = 1
    local len = #str

    local function skip_ws()
        while pos <= len and str:sub(pos, pos):match("%s") do
            pos = pos + 1
        end
    end

    local parse_value

    local function parse_string()
        pos = pos + 1 -- skip opening quote
        local parts = {}
        while pos <= len do
            local c = str:sub(pos, pos)
            if c == '\\' then
                -- Consume escape sequence
                pos = pos + 1
                local esc = str:sub(pos, pos)
                if esc == '"' then table.insert(parts, '"')
                elseif esc == '\\' then table.insert(parts, '\\')
                elseif esc == 'n' then table.insert(parts, '\n')
                elseif esc == 't' then table.insert(parts, '\t')
                elseif esc == 'r' then table.insert(parts, '\r')
                else table.insert(parts, esc)
                end
                pos = pos + 1
            elseif c == '"' then
                pos = pos + 1
                return table.concat(parts)
            else
                table.insert(parts, c)
                pos = pos + 1
            end
        end
        return table.concat(parts)
    end

    local function parse_number()
        local start_pos = pos
        if str:sub(pos, pos) == "-" then pos = pos + 1 end
        while pos <= len and str:sub(pos, pos):match("[%d%.eE%+%--]") do
            pos = pos + 1
        end
        return tonumber(str:sub(start_pos, pos - 1)) or 0
    end

    local function parse_object()
        pos = pos + 1 -- skip '{'
        local obj = {}
        skip_ws()
        if str:sub(pos, pos) == "}" then
            pos = pos + 1
            return obj
        end
        repeat
            skip_ws()
            if str:sub(pos, pos) ~= '"' then break end
            local key = parse_string()
            skip_ws()
            if str:sub(pos, pos) == ":" then pos = pos + 1 end
            skip_ws()
            local val = parse_value()
            obj[key] = val
            skip_ws()
            if str:sub(pos, pos) == "," then
                pos = pos + 1
            else
                break
            end
        until pos > len
        if str:sub(pos, pos) == "}" then pos = pos + 1 end
        return obj
    end

    local function parse_array()
        pos = pos + 1 -- skip '['
        local arr = {}
        skip_ws()
        if str:sub(pos, pos) == "]" then
            pos = pos + 1
            return arr
        end
        repeat
            skip_ws()
            local val = parse_value()
            table.insert(arr, val)
            skip_ws()
            if str:sub(pos, pos) == "," then
                pos = pos + 1
            else
                break
            end
        until pos > len
        if str:sub(pos, pos) == "]" then pos = pos + 1 end
        return arr
    end

    parse_value = function()
        skip_ws()
        if pos > len then return nil end
        local c = str:sub(pos, pos)
        if c == '{' then
            return parse_object()
        elseif c == '[' then
            return parse_array()
        elseif c == '"' then
            return parse_string()
        elseif c:match("[%d%-]") then
            return parse_number()
        elseif str:sub(pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif str:sub(pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        elseif str:sub(pos, pos + 3) == "null" then
            pos = pos + 4
            return nil
        end
        return nil
    end

    return parse_value()
end

function json.extract(val, path_keys, as_text)
    local cur = type(val) == "string" and json.parse(val) or val
    if not cur then return nil end

    for _, key in ipairs(path_keys) do
        if type(cur) ~= "table" then return nil end
        local num_k = tonumber(key)
        if num_k and cur[num_k + 1] ~= nil then
            cur = cur[num_k + 1] -- 0-based array index to 1-based Lua
        elseif cur[key] ~= nil then
            cur = cur[key]
        else
            return nil
        end
    end

    if as_text then
        if cur == nil then return nil end
        if type(cur) == "table" then return json.stringify(cur) end
        return tostring(cur)
    else
        if type(cur) == "table" then
            return json.stringify(cur)
        elseif type(cur) == "string" then
            return escape_str(cur)
        else
            return tostring(cur)
        end
    end
end

return json
