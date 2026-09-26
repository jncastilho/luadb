local aws_sigv4 = {}

-- Bitwise operations fallback for Lua versions (Lua 5.1/5.2/5.3/5.4/LuaJIT)
local bit = _G.bit32 or _G.bit
if not bit then
    -- Pure Lua bitwise fallback if no bit module exists
    bit = {}
    local math_floor = math.floor

    local function to_bits(n, bits)
        local t = {}
        for i = 1, bits do
            t[i] = n % 2
            n = math_floor(n / 2)
        end
        return t
    end

    local function from_bits(t)
        local n = 0
        local p = 1
        for i = 1, #t do
            n = n + t[i] * p
            p = p * 2
        end
        return n
    end

    function bit.bxor(a, b)
        local ta = to_bits(a, 32)
        local tb = to_bits(b, 32)
        local res = {}
        for i = 1, 32 do
            res[i] = (ta[i] ~= tb[i]) and 1 or 0
        end
        return from_bits(res)
    end

    function bit.band(a, b)
        local ta = to_bits(a, 32)
        local tb = to_bits(b, 32)
        local res = {}
        for i = 1, 32 do
            res[i] = (ta[i] == 1 and tb[i] == 1) and 1 or 0
        end
        return from_bits(res)
    end

    function bit.bnot(a)
        local ta = to_bits(a, 32)
        local res = {}
        for i = 1, 32 do
            res[i] = (ta[i] == 0) and 1 or 0
        end
        return from_bits(res)
    end

    function bit.bor(a, b)
        local ta = to_bits(a, 32)
        local tb = to_bits(b, 32)
        local res = {}
        for i = 1, 32 do
            res[i] = (ta[i] == 1 or tb[i] == 1) and 1 or 0
        end
        return from_bits(res)
    end

    function bit.rshift(a, b)
        return math_floor(a / (2 ^ b))
    end

    function bit.lshift(a, b)
        return (a * (2 ^ b)) % 4294967296
    end

    function bit.ror(a, b)
        b = b % 32
        local ta = to_bits(a, 32)
        local res = {}
        for i = 1, 32 do
            local new_pos = i - b
            if new_pos < 1 then new_pos = new_pos + 32 end
            res[new_pos] = ta[i]
        end
        return from_bits(res)
    end
end

-- Pure Lua SHA-256 implementation
local function sha256_hash(msg)
    local K = {
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    }

    local H = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    }

    local len = #msg
    local bit_len = len * 8
    msg = msg .. "\128"
    local pad_len = (56 - (#msg % 64)) % 64
    msg = msg .. string.rep("\0", pad_len)

    -- Append 64-bit length
    local high_len = math.floor(bit_len / 4294967296)
    local low_len = bit_len % 4294967296
    local bytes = {}
    for i = 1, 4 do
        bytes[i] = string.char(bit.band(bit.rshift(high_len, (4 - i) * 8), 0xFF))
    end
    for i = 1, 4 do
        bytes[4 + i] = string.char(bit.band(bit.rshift(low_len, (4 - i) * 8), 0xFF))
    end
    msg = msg .. table.concat(bytes)

    local W = {}
    for chunk_start = 1, #msg, 64 do
        local chunk = msg:sub(chunk_start, chunk_start + 63)
        for i = 1, 16 do
            local b1, b2, b3, b4 = string.byte(chunk, (i - 1) * 4 + 1, i * 4)
            W[i] = (b1 * 16777216) + (b2 * 65536) + (b3 * 256) + b4
        end
        for i = 17, 64 do
            local s0 = bit.bxor(bit.ror(W[i - 15], 7), bit.ror(W[i - 15], 18), bit.rshift(W[i - 15], 3))
            local s1 = bit.bxor(bit.ror(W[i - 2], 17), bit.ror(W[i - 2], 19), bit.rshift(W[i - 2], 10))
            W[i] = (W[i - 16] + s0 + W[i - 7] + s1) % 4294967296
        end

        local a, b, c, d, e, f, g, h = H[1], H[2], H[3], H[4], H[5], H[6], H[7], H[8]

        for i = 1, 64 do
            local S1 = bit.bxor(bit.ror(e, 6), bit.ror(e, 11), bit.ror(e, 25))
            local ch = bit.bxor(bit.band(e, f), bit.band(bit.bnot(e), g))
            local temp1 = (h + S1 + ch + K[i] + W[i]) % 4294967296
            local S0 = bit.bxor(bit.ror(a, 2), bit.ror(a, 13), bit.ror(a, 22))
            local maj = bit.bxor(bit.band(a, b), bit.band(a, c), bit.band(b, c))
            local temp2 = (S0 + maj) % 4294967296

            h = g
            g = f
            f = e
            e = (d + temp1) % 4294967296
            d = c
            c = b
            b = a
            a = (temp1 + temp2) % 4294967296
        end

        H[1] = (H[1] + a) % 4294967296
        H[2] = (H[2] + b) % 4294967296
        H[3] = (H[3] + c) % 4294967296
        H[4] = (H[4] + d) % 4294967296
        H[5] = (H[5] + e) % 4294967296
        H[6] = (H[6] + f) % 4294967296
        H[7] = (H[7] + g) % 4294967296
        H[8] = (H[8] + h) % 4294967296
    end

    local result = {}
    for i = 1, 8 do
        local val = H[i]
        local b1 = bit.band(bit.rshift(val, 24), 0xFF)
        local b2 = bit.band(bit.rshift(val, 16), 0xFF)
        local b3 = bit.band(bit.rshift(val, 8), 0xFF)
        local b4 = bit.band(val, 0xFF)
        table.insert(result, string.char(b1, b2, b3, b4))
    end
    return table.concat(result)
end

local function to_hex(str)
    local hex = {}
    for i = 1, #str do
        table.insert(hex, string.format("%02x", string.byte(str, i)))
    end
    return table.concat(hex)
end

function aws_sigv4.sha256(msg)
    return sha256_hash(msg)
end

function aws_sigv4.sha256_hex(msg)
    return to_hex(sha256_hash(msg))
end

function aws_sigv4.hmac_sha256(key, msg)
    local block_size = 64
    if #key > block_size then
        key = sha256_hash(key)
    end
    if #key < block_size then
        key = key .. string.rep("\0", block_size - #key)
    end

    local o_key_pad = {}
    local i_key_pad = {}
    for i = 1, block_size do
        local k = string.byte(key, i)
        table.insert(o_key_pad, string.char(bit.bxor(k, 0x5c)))
        table.insert(i_key_pad, string.char(bit.bxor(k, 0x36)))
    end

    local inner = sha256_hash(table.concat(i_key_pad) .. msg)
    return sha256_hash(table.concat(o_key_pad) .. inner)
end

function aws_sigv4.get_signature_key(secret_key, date_stamp, region_name, service_name)
    local k_date = aws_sigv4.hmac_sha256("AWS4" .. secret_key, date_stamp)
    local k_region = aws_sigv4.hmac_sha256(k_date, region_name)
    local k_service = aws_sigv4.hmac_sha256(k_region, service_name)
    local k_signing = aws_sigv4.hmac_sha256(k_service, "aws4_request")
    return k_signing
end

function aws_sigv4.create_authorization_header(config, method, uri, query_str, headers, payload)
    local access_key = config.access_key
    local secret_key = config.secret_key
    local region = config.region or "us-east-1"
    local service = "s3"

    local iso_date = config.iso_date or os.date("!%Y%m%dT%H%M%SZ")
    local date_stamp = iso_date:sub(1, 8)

    headers["x-amz-date"] = iso_date
    headers["x-amz-content-sha256"] = aws_sigv4.sha256_hex(payload or "")

    -- Canonical Headers
    local canonical_header_lines = {}
    local signed_header_keys = {}
    for k, v in pairs(headers) do
        local lk = k:lower()
        table.insert(signed_header_keys, lk)
    end
    table.sort(signed_header_keys)

    for _, lk in ipairs(signed_header_keys) do
        local val = ""
        for k, v in pairs(headers) do
            if k:lower() == lk then val = v:gsub("^%s*(.-)%s*$", "%1") end
        end
        table.insert(canonical_header_lines, lk .. ":" .. val .. "\n")
    end

    local signed_headers_str = table.concat(signed_header_keys, ";")
    local canonical_request = method .. "\n" ..
                              uri .. "\n" ..
                              query_str .. "\n" ..
                              table.concat(canonical_header_lines) .. "\n" ..
                              signed_headers_str .. "\n" ..
                              headers["x-amz-content-sha256"]

    local credential_scope = date_stamp .. "/" .. region .. "/" .. service .. "/aws4_request"
    local string_to_sign = "AWS4-HMAC-SHA256\n" ..
                           iso_date .. "\n" ..
                           credential_scope .. "\n" ..
                           aws_sigv4.sha256_hex(canonical_request)

    local signing_key = aws_sigv4.get_signature_key(secret_key, date_stamp, region, service)
    local signature = to_hex(aws_sigv4.hmac_sha256(signing_key, string_to_sign))

    local auth_header = "AWS4-HMAC-SHA256 Credential=" .. access_key .. "/" .. credential_scope ..
                        ", SignedHeaders=" .. signed_headers_str ..
                        ", Signature=" .. signature

    return auth_header
end

return aws_sigv4
