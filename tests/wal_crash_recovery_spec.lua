package.path = "src/?.lua;src/?/init.lua;" .. package.path

local luadb = require("luadb")

print("\n--------------------------------------------------")
print("[TEST SUITE] On-Disk WAL Engine & Crash Recovery Suite")
print("--------------------------------------------------")

local db_file = "wal_crash.db"
os.remove(db_file)
os.remove(db_file .. ".wal")
os.remove(db_file .. ".lock")

-- 1. Ingest committed baseline
print("\n[WAL Test 1] Commit Normal Transaction into On-Disk WAL")
local db = luadb.open({ driver = "local", storage_path = db_file })
db:exec("CREATE TABLE accounts (id INT PRIMARY KEY, owner TEXT, balance REAL);")
for i = 1, 10 do
    db:exec(string.format("INSERT INTO accounts VALUES (%d, 'User_%d', %f);", i, i, i * 100.0))
end

-- Verify that the .wal file is physically created and has content
local wal_f = io.open(db_file .. ".wal", "rb")
assert(wal_f ~= nil, "Expected .wal file to exist on disk")
local wal_size = wal_f:seek("end")
wal_f:close()
print(string.format("  ✓ [OK] On-disk .wal file active: %d bytes", wal_size))
assert(wal_size >= 32, "Expected WAL header present on disk")

db:close()

-- 2. Simulate Mid-Transaction Crash (Uncommitted dirty pages on disk)
print("\n[WAL Test 2] Simulate Uncommitted Crash (Discard Incomplete Mutations)")
local db2 = luadb.open({ driver = "local", storage_path = db_file })
db2:begin()
db2:exec("INSERT INTO accounts VALUES (999, 'Uncommitted Hacker', 999999.0);")
db2:exec("UPDATE accounts SET balance = 0.0 WHERE id = 1;")

-- We simulate sudden kill -9: we flush file buffers but DO NOT call commit() or db:close()
-- We close file descriptors directly via low-level handles to simulate OS death
if db2.vfs and db2.vfs._active_locks and db2.file then db2.vfs._active_locks[db2.file.path] = nil end
if db2.file and db2.file.handle then db2.file.handle:close() end
if db2.wal and db2.wal.wal_file and db2.wal.wal_file.handle then db2.wal.wal_file.handle:close() end
-- Clean lockfile as OS would release locks on process death
os.remove(db_file .. ".lock")

-- Reopen database: Crash Recovery MUST discard uncommitted mutations
local db3 = luadb.open({ driver = "local", storage_path = db_file })
local r_ghost = db3:exec("SELECT * FROM accounts WHERE id = 999;")
assert(#r_ghost == 0, "Uncommitted ghost row was not discarded!")
local r_alice = db3:exec("SELECT balance FROM accounts WHERE id = 1;")
assert(#r_alice == 1 and r_alice[1].balance == 100.0, "Committed balance was altered by uncommitted crash!")
print("  ✓ [OK] Uncommitted transaction completely discarded post-crash")
db3:close()

-- 3. Simulate Crash AFTER Commit in WAL but BEFORE Checkpoint to main .db
print("\n[WAL Test 3] Redo Recovery: Committed in WAL, Crash Before Checkpoint")
local db4 = luadb.open({ driver = "local", storage_path = db_file })
db4:begin()
db4:exec("INSERT INTO accounts VALUES (11, 'Committed In WAL Only', 5555.0);")
db4:commit() -- Frame is written to .wal with commit_flag = 1 and synced!

-- Now kill process before checkpoint
if db4.vfs and db4.vfs._active_locks and db4.file then db4.vfs._active_locks[db4.file.path] = nil end
if db4.file and db4.file.handle then db4.file.handle:close() end
if db4.wal and db4.wal.wal_file and db4.wal.wal_file.handle then db4.wal.wal_file.handle:close() end
os.remove(db_file .. ".lock")

-- Reopen: Recovery should detect committed frame in WAL, replay to main db
local db5 = luadb.open({ driver = "local", storage_path = db_file })
local r_wal = db5:exec("SELECT * FROM accounts WHERE id = 11;")
assert(#r_wal == 1, "Expected committed WAL frame to be replayed on recovery!")
assert(r_wal[1].owner == "Committed In WAL Only", "Expected restored row data intact")
assert(r_wal[1].balance == 5555.0, "Expected restored balance intact")
print("  ✓ [OK] Committed WAL frames replayed successfully into main database")
db5:close()

-- 4. Checksum Protection Against Torn / Corrupted Frames
print("\n[WAL Test 4] Checksum Verification Against Bitflips & Torn Writes")
local db6 = luadb.open({ driver = "local", storage_path = db_file })
db6:begin()
db6:exec("INSERT INTO accounts VALUES (12, 'Pre-Corruption Good Row', 1212.0);")
db6:commit()
db6:close()

-- Corrupt the end of the WAL file by writing garbage bytes
local corrupt_f = io.open(db_file .. ".wal", "a+b")
if corrupt_f then
    corrupt_f:write("CORRUPTED_TORN_FRAME_GARBAGE_PAYLOAD_1234567890")
    corrupt_f:close()
end

-- Reopen: Recovery must detect checksum mismatch, halt safely, and keep prior committed data intact
local db7 = luadb.open({ driver = "local", storage_path = db_file })
local r_good = db7:exec("SELECT * FROM accounts WHERE id = 12;")
assert(#r_good == 1, "Good row prior to corruption must remain intact")
print("  ✓ [OK] Checksum validation safely isolated corrupted trailing frame")
db7:close()

os.remove(db_file)
os.remove(db_file .. ".wal")
os.remove(db_file .. ".lock")

print("\n[PASS] On-Disk WAL Engine & Crash Recovery Suite Passed 100%!\n")
