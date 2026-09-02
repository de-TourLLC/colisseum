-- Register VM facade: parse -> compile to register bytecode -> run. Returns a
-- table of the chunk's return values (result[1] is the first). Semantics match
-- reference Lua. No loadstring. Runs on Lua/LuaJIT and Luau (globals resolve via
-- options.environment, else getfenv(0), else _G).
--
-- The in-memory program is kept as an opaque, fogged byte stream (see
-- reg-bytecode.encode_opaque / reg-runtime), so even the development path never
-- materializes the decoded program as plain Lua tables.

local RegCompiler = require("src.core.reg-compiler")
local RegBytecode = require("src.core.reg-bytecode")
local RegRuntime = require("src.core.reg-runtime")

local RegVM = {}

-- A deterministic dev fog. The backend injects a fresh per-build fog at bundle
-- time; this fixed one keeps local runs reproducible.
RegVM.fog = { 55, 19, 207, 101, 3, 88, 246, 13 }

local function host_environment()
    local getfenv = rawget(_G, "getfenv")
    if type(getfenv) == "function" then
        local ok, env = pcall(getfenv, 0)
        if ok and type(env) == "table" then return env end
    end
    return _G
end

function RegVM.compile(source)
    if type(source) ~= "string" then error("reg-vm: source must be a string") end
    return RegCompiler.compile(source)
end

function RegVM.opaque(proto, fog)
    local S, regs = RegBytecode.encode_opaque(proto, fog or RegVM.fog)
    return { S = S, r = regs, f = fog or RegVM.fog }
end

function RegVM.run(proto, options)
    options = options or {}
    if options.environment == nil then options.environment = host_environment() end
    local res = RegRuntime.run(RegVM.opaque(proto), options)
    -- normalize to a plain array with an `n` field
    local out = { n = res.n }
    for i = 1, res.n do out[i] = res[i] end
    return out
end

function RegVM.execute(source, options)
    return RegVM.run(RegVM.compile(source), options)
end

return RegVM