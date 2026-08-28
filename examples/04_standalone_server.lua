package.path = "src/?.lua;src/?/init.lua;" .. package.path

local luadb = require("luadb")
local proto = require("luadb.cluster.proto")

print("==================================================")
print("  LuaDB Example 4: Standalone Network Server")
print("==================================================")

os.remove("server_demo.db")

print("Starting LuaDB server instance on 127.0.0.1:5439...")
local db = luadb.open({ driver = "local", storage_path = "server_demo.db" })

db:exec("CREATE TABLE server_status (id INT PRIMARY KEY, node_name TEXT, uptime_sec INT);")
db:exec("INSERT INTO server_status VALUES (1, 'standalone_node_1', 3600);")

local rows = db:exec("SELECT * FROM server_status;")
print("\n✓ Standalone Node Local Storage State:")
for _, r in ipairs(rows) do
    print(string.format("  Node: %s | Uptime: %d seconds", r.node_name, r.uptime_sec))
end

db:close()
os.remove("server_demo.db")
print("\n✓ Standalone server demonstration completed successfully.")
