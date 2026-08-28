package.path = "src/?.lua;src/?/init.lua;" .. package.path

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("ASSERT FAILED: [%s] Expected %s, got %s", msg or "test", tostring(expected), tostring(actual)))
    else
        print(string.format("  ✓ [OK] %s", msg or "check"))
    end
end

print("\n--------------------------------------------------")
print("[TEST SUITE] Runnable Examples Verification Suite")
print("--------------------------------------------------")

-- Example 1: Embedded Local
print("\n[Example Test 1] Running examples/01_embedded_local.lua")
local ok1, err1 = pcall(function() dofile("examples/01_embedded_local.lua") end)
assert_eq(ok1, true, "Example 01 Embedded Local Execution")

-- Example 2: Embedded Memory
print("\n[Example Test 2] Running examples/02_embedded_memory.lua")
local ok2, err2 = pcall(function() dofile("examples/02_embedded_memory.lua") end)
assert_eq(ok2, true, "Example 02 Embedded Memory Execution")

-- Example 3: Embedded S3
print("\n[Example Test 3] Running examples/03_embedded_s3.lua")
local ok3, err3 = pcall(function() dofile("examples/03_embedded_s3.lua") end)
assert_eq(ok3, true, "Example 03 Embedded S3 Execution")

-- Example 4: Standalone Server
print("\n[Example Test 4] Running examples/04_standalone_server.lua")
local ok4, err4 = pcall(function() dofile("examples/04_standalone_server.lua") end)
assert_eq(ok4, true, "Example 04 Standalone Server Execution")

-- Example 5: Kamailio CDR Drain
print("\n[Example Test 5] Running examples/05_kamailio_cdr_drain.lua")
local ok5, err5 = pcall(function() dofile("examples/05_kamailio_cdr_drain.lua") end)
assert_eq(ok5, true, "Example 05 Kamailio CDR Drain Execution")

print("\n[PASS] Runnable Examples Suite Passed 100%!")
