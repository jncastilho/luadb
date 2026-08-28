package.path = "src/?.lua;src/?/init.lua;" .. package.path

local vfs = require("luadb.vfs")
local aws_sigv4 = require("luadb.vfs.aws_sigv4")

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("ASSERT FAILED: [%s] Expected %s, got %s", msg or "test", tostring(expected), tostring(actual)))
    else
        print(string.format("  ✓ [OK] %s: %s", msg or "check", tostring(actual)))
    end
end

print("\n--------------------------------------------------")
print("[TEST SUITE] Virtual File System (VFS)")
print("--------------------------------------------------")

-- 1. Memory VFS Test
print("\n[VFS Test 1] In-Memory RAM Storage Driver")
local mem = vfs.create("memory")
local f1 = mem:open("test.bin")
print("  > Opened virtual file 'test.bin'")
f1:write(0, "HELLO WORLD")
print("  > Wrote 11 bytes at offset 0: 'HELLO WORLD'")
assert_eq(f1:read(0, 5), "HELLO", "MemoryVFS Read Offset 0 Length 5")
assert_eq(f1:read(6, 5), "WORLD", "MemoryVFS Read Offset 6 Length 5")
assert_eq(f1:size(), 11, "MemoryVFS Total Buffer Size")
f1:close()
print("  > Closed file 'test.bin'")

-- 2. Local File VFS Test
print("\n[VFS Test 2] Local Disk File Driver")
local local_vfs = vfs.create("local", { base_dir = "." })
local f2 = local_vfs:open("temp_test.db", "w+b")
print("  > Opened local disk file 'temp_test.db'")
f2:write(0, "LUADB_LOCAL_TEST")
f2:sync()
print("  > Flushed buffer to disk")
assert_eq(f2:read(0, 16), "LUADB_LOCAL_TEST", "LocalVFS Read Offset 0 Length 16")
f2:close()
local_vfs:delete("temp_test.db")
print("  > Cleaned up temp file 'temp_test.db'")

-- 3. S3 SigV4 Test
print("\n[VFS Test 3] Amazon S3 SigV4 Authentication Signer")
local headers = { Host = "mybucket.s3.us-east-1.amazonaws.com" }
local config = { access_key = "AKIAEXAMPLE", secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", region = "us-east-1", iso_date = "20260814T120000Z" }
local auth = aws_sigv4.create_authorization_header(config, "GET", "/db.bin", "", headers, "")
print("  > Generated Authorization Header:")
print("    " .. auth)

print("\n[PASS] VFS Test Suite Completed Successfully!")
