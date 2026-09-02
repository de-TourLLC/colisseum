-- Sandboxed VM environment + anti-hook anchor generators.
--
-- Both VM backends (register, native) hand the interpreter a `program.environment`
-- table instead of the real globals. The VM's own code always resolves identifiers
-- through that table, so `debug`, `load*`, `getfenv/setfenv` are simply absent:
-- payload code that tries `debug.gethook`, `pcall(debug.gethook)` or
-- `getfenv(2)` reads nil -- the audit's "hook spy / env escape" vectors die at
-- the source, before any hook gets a chance to fire.
--
-- The expression builders return Lua source SNAPSHOTS (strings) that the backends
-- splice into their bundles verbatim. `expression()` yields the sandbox table;
-- `anchor()` yields `{ d = <host debug table>, g = <gethook>, s = <sethook> }`
-- captured from the HOST chunk scope (so a later `debug = {}` rebinding or
-- gethook/sethook swap is detected by the interpreter's sampler by identity).

local Environment = {}

-- Escaped string literal (every byte as \ddd) so the emitted bundle never
-- carries a scannable plaintext name like "loadstring" or "debug".
local function literal(name)
    return '"' .. name:gsub(".", function(c)
        return "\\" .. string.format("%03d", c:byte())
    end) .. '"'
end

local lan_ban = {}
for _, n in ipairs({ "debug", "getfenv", "setfenv", "loadstring", "load", "dofile", "loadfile" }) do
    lan_ban[#lan_ban + 1] = literal(n)
end
local lan_ban_literal = "{" .. table.concat(lan_ban, ",") .. "}"

-- Sandboxed globals for a VM payload. Everything the running script's own
-- environment / _G provides is copied EXCEPT the escape hatches the audit wants
-- gone: the debug API (hook spy V-H5, inspect V-H1), getfenv/setfenv (env escape
-- V-M4/A-2), and the code-loaders loadstring/load/loadfile/dofile (dynamic re-
-- encryption V-H1/A-4). `require` stays: real payloads (Roblox) depend on it.
-- pcall/type/tostring are re-bound to private refs so hook-carrying callbacks
-- cannot be smuggled through a wrapped call; `_G` inside the payload is the
-- sandbox itself, so rawget(_G,"debug") resolves to nil no matter what.
Environment.expression = function()
    return "(function()local g=rawget(_G," .. literal("getfenv") .. ");g=(type(g)==\"function\" and g(0)) or _G " ..
        "local e={} for k,v in next,g do e[k]=v end " ..
        "for k in next," .. lan_ban_literal .. " do e[k]=nil end " ..
        "local p,t,ts=pcall,type,tostring e.pcall=function(f,...) return p(f,...) end e.type=t e.tostring=ts " ..
        "e._G=e return e end)()"
end

-- Host debug anchor captured INSIDE the bundle's own chunk scope (the real host
-- globals), independently of the sandboxed payload environment. Identity-checked
-- by the interpreter's stride-jittered sampler.
Environment.anchor = function()
    return "(function(t) return {d=t,g=t.gethook,s=t.sethook} end)(debug)"
end

return Environment