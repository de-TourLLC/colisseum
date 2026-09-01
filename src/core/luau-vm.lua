local VM = {}

VM.name = "fiu"
VM.source = "vendor/Fiu/Source.lua"
VM.license = "MIT"

local function backend(path)
    local file = path or VM.source
    local chunk, message = loadfile(file)
    if not chunk then error("luau-vm: cannot load backend: " .. tostring(message)) end
    local value = chunk()
    if type(value) ~= "table" or type(value.luau_load) ~= "function" then
        error("luau-vm: backend does not expose the Fiu API")
    end
    return value
end

function VM.load(bytecode, environment, settings, path)
    if type(bytecode) ~= "string" and type(bytecode) ~= "buffer" then
        error("luau-vm: bytecode must be a string or buffer")
    end
    local api = backend(path)
    local options = settings or api.luau_newsettings()
    api.luau_validatesettings(options)
    local closure, close = api.luau_load(bytecode, environment or {}, options)
    return closure, close
end

function VM.deserialize(bytecode, settings, path)
    local api = backend(path)
    local options = settings or api.luau_newsettings()
    api.luau_validatesettings(options)
    return api.luau_deserialize(bytecode, options)
end

function VM.available(path)
    local ok = pcall(backend, path)
    return ok
end

return VM
