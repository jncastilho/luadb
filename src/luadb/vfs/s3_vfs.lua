local aws_sigv4 = require("luadb.vfs.aws_sigv4")

local S3VFS = {}
S3VFS.__index = S3VFS

function S3VFS.new(config)
    config = config or {}
    local self = setmetatable({}, S3VFS)
    self.bucket = config.bucket or "luadb-default-bucket"
    self.region = config.region or "us-east-1"
    self.access_key = config.access_key or os.getenv("AWS_ACCESS_KEY_ID") or "mock_key"
    self.secret_key = config.secret_key or os.getenv("AWS_SECRET_ACCESS_KEY") or "mock_secret"
    self.endpoint = config.endpoint or string.format("https://%s.s3.%s.amazonaws.com", self.bucket, self.region)
    self.http_handler = config.http_handler -- optional custom HTTP callback
    self.cache = {} -- in-memory cached content per object name
    self.dirty = {} -- track modified object flags
    return self
end

-- Default HTTP requester using popen curl or http_handler
function S3VFS:_http_request(method, path, headers, body)
    if self.http_handler then
        return self.http_handler(method, self.endpoint .. path, headers, body)
    end

    -- CLI cURL fallback execution
    local cmd = { "curl -s -i -X " .. method }
    for k, v in pairs(headers) do
        table.insert(cmd, string.format('-H "%s: %s"', k, v))
    end
    local tmp_file_path = nil
    if body and #body > 0 then
        tmp_file_path = os.tmpname()
        local f = io.open(tmp_file_path, "wb")
        if f then
            f:write(body)
            f:close()
            table.insert(cmd, string.format('--data-binary "@%s"', tmp_file_path))
        end
    end
    table.insert(cmd, string.format('"%s%s"', self.endpoint, path))

    local exec_cmd = table.concat(cmd, " ")
    local handle = io.popen(exec_cmd)
    if not handle then
        if tmp_file_path then os.remove(tmp_file_path) end
        return nil, 500, "Failed to execute curl command"
    end

    local response = handle:read("*a")
    handle:close()
    if tmp_file_path then os.remove(tmp_file_path) end

    local header_part, body_part = response:match("^(.-)\r?\n\r?\n(.*)$")
    if not header_part then
        header_part = response
        body_part = ""
    end

    local status = tonumber(header_part:match("HTTP/%d%.?%d?%s+(%d+)")) or 200
    return body_part or "", status, header_part
end

function S3VFS:open(filename, mode)
    if not self.cache[filename] then
        -- Attempt to fetch initial object from S3 if it exists
        local headers = { Host = self.bucket .. ".s3." .. self.region .. ".amazonaws.com" }
        local auth = aws_sigv4.create_authorization_header(self, "GET", "/" .. filename, "", headers, "")
        headers["Authorization"] = auth

        local body, status = self:_http_request("GET", "/" .. filename, headers, "")
        if status == 200 then
            self.cache[filename] = body
        else
            self.cache[filename] = ""
        end
    end

    local file_obj = {
        name = filename,
        vfs = self
    }

    function file_obj:read(offset, length)
        local buffer = self.vfs.cache[self.name] or ""
        local start_pos = offset + 1
        local end_pos = start_pos + length - 1
        if start_pos > #buffer then return "" end
        return buffer:sub(start_pos, math.min(end_pos, #buffer))
    end

    function file_obj:write(offset, data)
        local buffer = self.vfs.cache[self.name] or ""
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
        self.vfs.cache[self.name] = prefix .. data .. suffix
        self.vfs.dirty[self.name] = true
        return true
    end

    function file_obj:size()
        local buffer = self.vfs.cache[self.name] or ""
        return #buffer
    end

    function file_obj:sync()
        if self.vfs.dirty[self.name] then
            local payload = self.vfs.cache[self.name] or ""
            local headers = { Host = self.vfs.bucket .. ".s3." .. self.vfs.region .. ".amazonaws.com" }
            local auth = aws_sigv4.create_authorization_header(self.vfs, "PUT", "/" .. self.name, "", headers, payload)
            headers["Authorization"] = auth

            local _, status, err = self.vfs:_http_request("PUT", "/" .. self.name, headers, payload)
            if status >= 200 and status < 300 then
                self.vfs.dirty[self.name] = false
                return true
            else
                return false, "Failed to upload to S3: status " .. tostring(status) .. " " .. tostring(err)
            end
        end
        return true
    end

    function file_obj:close()
        return self:sync()
    end

    return file_obj
end

function S3VFS:exists(filename)
    return self.cache[filename] ~= nil
end

function S3VFS:delete(filename)
    self.cache[filename] = nil
    self.dirty[filename] = nil
    local headers = { Host = self.bucket .. ".s3." .. self.region .. ".amazonaws.com" }
    local auth = aws_sigv4.create_authorization_header(self, "DELETE", "/" .. filename, "", headers, "")
    headers["Authorization"] = auth
    self:_http_request("DELETE", "/" .. filename, headers, "")
    return true
end

return S3VFS
