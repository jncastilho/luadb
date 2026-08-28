package.path = "src/?.lua;src/?/init.lua;" .. package.path

local luadb = require("luadb")
local json = require("luadb.sql.json")

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error(string.format("ASSERT FAILED: [%s] Expected %s, got %s", msg or "test", tostring(expected), tostring(actual)))
    else
        print(string.format("  ✓ [OK] %s: %s", msg or "check", tostring(actual)))
    end
end

print("\n--------------------------------------------------")
print("[TEST SUITE] Native JSON / JSONB Engine & Operators")
print("--------------------------------------------------")

-- 1. Test Pure Lua Micro JSON Parser & Stringifier
print("\n[JSON Test 1] Pure Lua JSON Encoder / Decoder / Extractor")
local parsed_obj = json.parse('{"user": "Alice", "meta": {"role": "admin", "score": 98}}')
assert_eq(parsed_obj.user, "Alice", "Parsed JSON Field user")
assert_eq(parsed_obj.meta.role, "admin", "Parsed Nested Field role")

local ext_text = json.extract(parsed_obj, { "meta", "role" }, true)
assert_eq(ext_text, "admin", "JSON Extract Text (->>)")

local ext_obj = json.extract(parsed_obj, { "meta" }, false)
assert_eq(type(ext_obj) == "string" and ext_obj:find('"role":"admin"') ~= nil and ext_obj:find('"score":98') ~= nil, true, "JSON Extract Object (->)")

-- 2. Test JSON Table Creation & Insertion
print("\n[JSON Test 2] JSONB Column Creation & Insertion")
os.remove("json_test.db")
local db = luadb.open({ driver = "local", storage_path = "json_test.db" })
db:exec("CREATE TABLE customers (id INT PRIMARY KEY, details JSONB);")

db:exec("INSERT INTO customers VALUES (1, '{\"name\": \"Alice\", \"address\": {\"city\": \"New York\", \"zip\": \"10001\"}}');")
db:exec("INSERT INTO customers VALUES (2, '{\"name\": \"Bob\", \"address\": {\"city\": \"San Francisco\", \"zip\": \"94105\"}}');")

-- 3. Test ->> Unquoted Text Extraction Operator
print("\n[JSON Test 3] Text Extraction Operator (->>)")
local names = db:exec("SELECT details->>'name' AS name FROM customers WHERE id = 1;")
assert_eq(names[1].name, "Alice", "Extracted Name via ->>")

-- 4. Test Chained JSON Path Extraction
print("\n[JSON Test 4] Chained JSON Path Extraction (->'address'->>'city')")
local cities = db:exec("SELECT details->'address'->>'city' AS city_name FROM customers WHERE id = 2;")
assert_eq(cities[1].city_name, "San Francisco", "Extracted Nested City via Chained Path")

-- 5. Test WHERE Clause Filtering on JSON Fields
print("\n[JSON Test 5] WHERE Filter on JSON Attributes")
local matches = db:exec("SELECT details->>'name' AS customer_name FROM customers WHERE details->'address'->>'zip' = '10001';")
assert_eq(#matches, 1, "Matching JSON Row Count")
assert_eq(matches[1].customer_name, "Alice", "Matching Customer Name")

db:close()
os.remove("json_test.db")

print("\n[PASS] Native JSON / JSONB Engine & Operators Suite Passed 100%!")
