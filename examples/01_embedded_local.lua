package.path = "src/?.lua;src/?/init.lua;" .. package.path

local luadb = require("luadb")

print("==================================================")
print("  LuaDB Example 1: Embedded Local File RDBMS")
print("==================================================")

os.remove("example_local.db")

local db = luadb.open({
    driver = "local",
    storage_path = "example_local.db"
})

-- 1. Create Schema with Foreign Key & Constraints
db:exec([[
CREATE TABLE departments (
    id INT PRIMARY KEY,
    name TEXT
);
]])

db:exec([[
CREATE TABLE employees (
    id INT PRIMARY KEY,
    name TEXT,
    dept_id INT,
    salary REAL,
    FOREIGN KEY (dept_id) REFERENCES departments(id) ON DELETE CASCADE
);
]])

print("\n✓ Schema created successfully.")

-- 2. Ingest Sample Data
db:exec("INSERT INTO departments VALUES (1, 'Engineering');")
db:exec("INSERT INTO departments VALUES (2, 'Operations');")

db:exec("INSERT INTO employees VALUES (101, 'Alice', 1, 125000.0);")
db:exec("INSERT INTO employees VALUES (102, 'Bob', 1, 95000.0);")
db:exec("INSERT INTO employees VALUES (103, 'Charlie', 2, 85000.0);")

print("✓ Data inserted successfully.")

-- 3. Run Query & Iteration
local rows = db:exec("SELECT * FROM employees ORDER BY salary DESC;")
print("\n[Query Results: Employees by Salary]")
for _, row in ipairs(rows) do
    print(string.format("  ID: %d | Name: %-10s | Salary: $%.2f", row.id, row.name, row.salary))
end

-- 4. Foreign Key Cascading Delete
print("\nDeleting 'Engineering' Department (ID: 1)...")
db:exec("DELETE FROM departments WHERE id = 1;")

local remaining = db:exec("SELECT * FROM employees;")
print("[Remaining Employees Post-Cascade Delete]")
for _, row in ipairs(remaining) do
    print(string.format("  ID: %d | Name: %-10s", row.id, row.name))
end

db:close()
os.remove("example_local.db")
print("\n✓ Database closed and cleaned up.")
