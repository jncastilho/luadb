package.path = "src/?.lua;src/?/init.lua;" .. package.path

local vfs = require("luadb.vfs")
local serializer = require("luadb.storage.serializer")
local page_mgr = require("luadb.storage.page")
local WAL = require("luadb.storage.wal")
local BTree = require("luadb.storage.btree")

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("ASSERT FAILED: [%s] Expected %s, got %s", msg or "test", tostring(expected), tostring(actual)))
    else
        print(string.format("  ✓ [OK] %s: %s", msg or "check", tostring(actual)))
    end
end

print("\n--------------------------------------------------")
print("[TEST SUITE] Binary Serialization, Pages & B+Tree")
print("--------------------------------------------------")

-- 1. Serializer Test
print("\n[Storage Test 1] Binary Type Serializer & Deserializer")
local input_row = { 42, "hello", true, nil, 3.14159 }
print("  > Input row tuple: { 42, 'hello', true, nil, 3.14159 }")
local packed = serializer.pack_row(input_row, 5)
print(string.format("  > Packed binary stream length: %d bytes", #packed))
local unpacked = serializer.unpack_row(packed)
assert_eq(unpacked[1], 42, "Serializer Integer Field")
assert_eq(unpacked[2], "hello", "Serializer String Field")
assert_eq(unpacked[3], true, "Serializer Boolean Field")
assert_eq(unpacked[4], nil, "Serializer Nil Field")
assert_eq(unpacked[5], 3.14159, "Serializer Double Float Field")

-- 2. Page Manager Test
print("\n[Storage Test 2] 4096-Byte Fixed Page Buffer")
local page = page_mgr.new_page(page_mgr.PAGE_TYPE_LEAF)
assert_eq(#page, 4096, "Page Buffer Fixed Size")
assert_eq(page_mgr.get_type(page), page_mgr.PAGE_TYPE_LEAF, "Page Header Type")

-- 3. BTree Storage & WAL Test
print("\n[Storage Test 3] B+Tree Row Indexing & Lookup")
local mem = vfs.create("memory")
local file = mem:open("btree_test.db")
local wal = WAL.new(file)
local btree = BTree.new(wal, 1)

print("  > Inserting key 100: {'John Doe', 'john@example.com'}")
btree:insert(100, { "John Doe", "john@example.com" })
print("  > Inserting key 200: {'Jane Smith', 'jane@example.com'}")
btree:insert(200, { "Jane Smith", "jane@example.com" })

local r1 = btree:find(100)
local r2 = btree:find(200)
assert_eq(r1[1], "John Doe", "B+Tree Lookup Key 100")
assert_eq(r2[1], "Jane Smith", "B+Tree Lookup Key 200")

-- 4. BTree Delete Test
print("\n[Storage Test 4] B+Tree Record Deletion")
print("  > Deleting record with Key 100")
btree:delete(100)
assert_eq(btree:find(100), nil, "B+Tree Deleted Key Lookup")

print("\n[PASS] Storage & B+Tree Suite Completed Successfully!")
