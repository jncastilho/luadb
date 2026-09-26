#!/usr/bin/env luajit

package.path = "src/?.lua;src/?/init.lua;" .. package.path

local europadb = require("europadb")
local pg_server = require("europadb.net.pg_server")

local db_path = arg[1] or "app.edb"
local port = tonumber(arg[2]) or 5433

local db = europadb.open({ driver = "local", storage_path = db_path })

-- Auto-seed sample demo data if catalog is empty
if not db.executor.catalog["demo"] then
    db:exec("CREATE TABLE IF NOT EXISTS demo (id INT PRIMARY KEY, title TEXT, category TEXT);")
    db:exec("INSERT INTO demo VALUES (1, 'Welcome to EuropaDB', 'General');")
    db:exec("INSERT INTO demo VALUES (2, 'PostgreSQL Wire Protocol Gateway', 'Network');")
    db:exec("INSERT INTO demo VALUES (3, 'Pure Lua B+Tree Storage Engine', 'Database');")
end

if not db.executor.catalog["employees"] then
    db:exec("CREATE TABLE IF NOT EXISTS employees (id INT PRIMARY KEY, name TEXT, salary REAL, role TEXT);")
    db:exec("INSERT INTO employees VALUES (1, 'Alice', 95000, 'Engineering');")
    db:exec("INSERT INTO employees VALUES (2, 'Bob', 82000, 'Design');")
    db:exec("INSERT INTO employees VALUES (3, 'Charlie', 110000, 'Engineering');")
end

pg_server.start(db, port)
