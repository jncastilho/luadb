local vfs = {}

-- Factory function to instantiate a VFS driver
function vfs.create(driver_type, config)
    driver_type = driver_type or "local"
    if driver_type == "local" then
        local LocalVFS = require("luadb.vfs.local_vfs")
        return LocalVFS.new(config)
    elseif driver_type == "memory" then
        local MemoryVFS = require("luadb.vfs.memory_vfs")
        return MemoryVFS.new(config)
    elseif driver_type == "s3" then
        local S3VFS = require("luadb.vfs.s3_vfs")
        return S3VFS.new(config)
    else
        error("Unsupported VFS driver type: " .. tostring(driver_type))
    end
end

return vfs
