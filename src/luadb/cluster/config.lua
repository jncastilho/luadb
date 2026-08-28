local config = {}

function config.parse_nodes(env_val)
    local nodes = {}
    local val = env_val or os.getenv("LUADB_NODES") or ""
    for item in val:gmatch("[^,]+") do
        local cleaned = item:match("^%s*(.-)%s*$")
        if cleaned and cleaned ~= "" then
            local host, port_str = cleaned:match("^([^:]+):?(%d*)$")
            local port = tonumber(port_str) or 5433
            table.insert(nodes, {
                raw = cleaned,
                host = host,
                port = port
            })
        end
    end
    return nodes
end

function config.get_node_id()
    return os.getenv("LUADB_NODE_ID") or ("node_" .. (os.getenv("PORT") or "5433"))
end

function config.get_ttl_seconds()
    return tonumber(os.getenv("LUADB_REPLICATION_TTL")) or 86400 -- 24 hours
end

return config
