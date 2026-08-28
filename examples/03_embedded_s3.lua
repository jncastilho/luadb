package.path = "src/?.lua;src/?/init.lua;" .. package.path

local luadb = require("luadb")

print("==================================================")
print("  LuaDB Example 3: Amazon S3 Cloud Storage VFS")
print("==================================================")

-- Note: In production, configure bucket, region, access_key, secret_key.
-- In test mode without credentials, S3 driver operates with mock VFS buffer.
local db = luadb.open({
    driver = "s3",
    storage_path = "cloud_database.db",
    s3 = {
        bucket = "telecom-cdr-archive",
        region = "us-east-1",
        access_key = os.getenv("AWS_ACCESS_KEY_ID") or "MOCK_KEY",
        secret_key = os.getenv("AWS_SECRET_ACCESS_KEY") or "MOCK_SECRET"
    }
})

print("✓ Connected to S3 Cloud VFS Driver (Bucket: telecom-cdr-archive).")

db:exec([[
CREATE TABLE s3_logs (
    id INT PRIMARY KEY,
    event TEXT,
    ts TIMESTAMP
);
]])

db:exec("INSERT INTO s3_logs VALUES (1, 'Cloud Sync Initialized', '2026-08-15 01:25:00');")

local rows = db:exec("SELECT * FROM s3_logs;")
print("\n[S3 Database Content]")
for _, r in ipairs(rows) do
    print(string.format("  ID: %d | Event: %s | TS: %s", r.id, r.event, r.ts))
end

db:close()
print("\n✓ S3 Cloud database handle closed successfully.")
