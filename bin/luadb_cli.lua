#!/usr/bin/env lua

package.path = "src/?.lua;src/?/init.lua;" .. package.path

local luadb = require("luadb")

local db_path = arg[1] or "app.db"
local driver = "local"

if db_path == ":memory:" or db_path == "memory" then
    driver = "memory"
    db_path = "memory.db"
end

print("=========================================================")
print("  LuaDB Interactive CLI (v1.0.0)")
print("  Connected to " .. driver .. " database: [" .. db_path .. "]")
print("  Type '\\dt' to list tables, '\\d <table>' for schema, '\\q' to quit.")
print("  Press Ctrl+D or type '\\q' anytime to exit.")
print("=========================================================\n")

local db = luadb.open({ driver = driver, storage_path = db_path })

local function format_ascii_table(rows)
    if not rows or #rows == 0 then
        print("  (0 rows)")
        return
    end

    local cols = {}
    local col_set = {}
    for _, row in ipairs(rows) do
        for k, _ in pairs(row) do
            if not col_set[k] then
                col_set[k] = true
                table.insert(cols, k)
            end
        end
    end
    table.sort(cols)

    local widths = {}
    for _, c in ipairs(cols) do
        widths[c] = #tostring(c)
    end
    for _, row in ipairs(rows) do
        for _, c in ipairs(cols) do
            local val_str = tostring(row[c] ~= nil and row[c] or "NULL")
            if #val_str > widths[c] then
                widths[c] = #val_str
            end
        end
    end

    local border_parts = {}
    for _, c in ipairs(cols) do
        table.insert(border_parts, string.rep("-", widths[c] + 2))
    end
    local top_border = "+" .. table.concat(border_parts, "+") .. "+"

    local header_parts = {}
    for _, c in ipairs(cols) do
        table.insert(header_parts, string.format(" %-" .. widths[c] .. "s ", c))
    end
    local header_row = "|" .. table.concat(header_parts, "|") .. "|"

    print(top_border)
    print(header_row)
    print(top_border)

    for _, row in ipairs(rows) do
        local row_parts = {}
        for _, c in ipairs(cols) do
            local val = row[c]
            local val_str = tostring(val ~= nil and val or "NULL")
            if type(val) == "number" then
                table.insert(row_parts, string.format(" %" .. widths[c] .. "s ", val_str))
            else
                table.insert(row_parts, string.format(" %-" .. widths[c] .. "s ", val_str))
            end
        end
        print("|" .. table.concat(row_parts, "|") .. "|")
    end

    print(top_border)
    print(string.format("  (%d row%s)\n", #rows, #rows == 1 and "" or "s"))
end

local function handle_meta(cmd)
    cmd = cmd:gsub("%s+$", "")
    if cmd == "\\q" or cmd == "\\quit" or cmd == "exit" or cmd == "quit" then
        return "QUIT"
    elseif cmd == "\\dt" then
        local cat = db.executor.catalog
        local table_rows = {}
        for t_name, meta in pairs(cat) do
            table.insert(table_rows, { Table = t_name, Columns = #meta.columns, AutoInc = meta.auto_inc })
        end
        print("\nList of Tables:")
        format_ascii_table(table_rows)
    elseif cmd:sub(1, 3) == "\\d " then
        local t_name = cmd:sub(4):gsub("%s+", "")
        local meta = db.executor.catalog[t_name]
        if not meta then
            print("Table not found: " .. t_name)
        else
            local col_rows = {}
            for _, col in ipairs(meta.columns) do
                table.insert(col_rows, {
                    Column = col.name,
                    Type = col.type,
                    PrimaryKey = col.primary_key and "YES" or "NO"
                })
            end
            print("\nTable Schema [" .. t_name .. "]:")
            format_ascii_table(col_rows)
        end
    elseif cmd == "\\help" or cmd == "\\?" then
        print("\nMeta Commands:")
        print("  \\dt           List all tables in database")
        print("  \\d <table>    Describe schema of specified table")
        print("  \\q           Quit CLI")
        print("  \\help         Show this help menu\n")
    else
        print("Unknown command: " .. cmd .. ". Type '\\help' for available commands.")
    end
    return "CONTINUE"
end

local running = true

while running do
    io.write("luadb=> ")
    io.flush()
    local line = io.read("*line")
    
    -- Ctrl+D handling
    if not line then
        print("\nGoodbye!")
        break
    end

    line = line:gsub("^%s*(.-)%s*$", "%1")
    line = line:gsub("^lua%s+bin/luadb_cli%.lua%s*[^%s]*%s*", "")
    line = line:gsub("^lua%s+", "")

    if #line > 0 then
        if line:sub(1, 1) == "\\" or line:lower() == "exit" or line:lower() == "quit" then
            local action = handle_meta(line)
            if action == "QUIT" then
                print("Goodbye!")
                break
            end
        else
            if not line:match(";%s*$") then
                line = line .. ";"
            end
            local res, err = db:exec(line)
            if err then
                print("ERROR: " .. tostring(err) .. "\n")
            elseif type(res) == "table" and res.message then
                print("SUCCESS: " .. res.message .. "\n")
            elseif type(res) == "table" then
                format_ascii_table(res)
            else
                print("OK\n")
            end
        end
    end
end

db:close()
