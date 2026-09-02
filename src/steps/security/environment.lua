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

-- Names hidden from the sandbox: the debug API, env accessors, and code loaders.
-- Emitted as a SET literal `{[name]=true,...}` (escaped bytes, no plaintext) for
-- O(1) masking in both the copy loop and the __index fallback.
local ban_names = { "debug", "getfenv", "setfenv", "loadstring", "load", "dofile", "loadfile" }
local ban_set = {}
for _, n in ipairs(ban_names) do
    ban_set[#ban_set + 1] = "[" .. literal(n) .. "]=true"
end
local ban_set_literal = "{" .. table.concat(ban_set, ",") .. "}"

-- Sandboxed globals for a VM payload. Everything the running script's own
-- environment / _G provides is copied EXCEPT the escape hatches the audit wants
-- gone: the debug API (hook spy V-H5, inspect V-H1), getfenv/setfenv (env escape
-- V-M4/A-2), and the code-loaders loadstring/load/loadfile/dofile (dynamic re-
-- encryption V-H1/A-4). `require` stays: real payloads (Roblox) depend on it.
-- pcall/type/tostring are re-bound to private refs so hook-carrying callbacks
-- cannot be smuggled through a wrapped call; `_G` inside the payload is the
-- sandbox itself, so rawget(_G,"debug") resolves to nil no matter what.
-- IMPORTANT (portability): the previous implementation seeded the sandbox by
-- iterating `getfenv(0)`. On Luau that table is NOT enumerable (`next` yields
-- nothing), so the sandbox came out EMPTY and every payload global -- `print`,
-- `string`, ... -- resolved to nil ("attempt to call a nil value"). LuaJIT's
-- `getfenv(0)` is `_G` and enumerable, which is why it only broke on Luau.
--
-- Fix: enumerate `_G`, which IS enumerable on both LuaJIT and Luau and carries the
-- builtins (print/string/table/math/os/pcall/debug/...). Copying them as RAW slots
-- also keeps the anti-tamper guard working -- it reads globals with `rawget`, which
-- does not traverse `__index`. A metatable then forwards any name NOT copied (the
-- script environment's own globals: on Roblox `game`, `workspace`, `script`, and
-- injected executor globals) to the live base env, so real payloads keep working.
-- `__metatable=false` hides that metatable from `getmetatable`, so the guard's
-- global-metatable-interception check does not false-positive on our own sandbox.
-- Banned names (debug/getfenv/setfenv/load*/dofile) are masked in BOTH the copy and
-- the `__index`, so `_G.debug` / `rawget(_G,"debug")` are nil no matter what.
Environment.expression = function()
    return "(function()" ..
        "local rg=rawget local gf=rg(_G," .. literal("getfenv") .. ") " ..
        "local base=(type(gf)==\"function\" and gf(0)) or _G " ..
        "local ban=" .. ban_set_literal .. " " ..
        "local e={} " ..
        "for k,v in next,_G do if not ban[k] then e[k]=v end end " ..
        "for k,v in next,base do if e[k]==nil and not ban[k] then e[k]=v end end " ..
        "local p,t,ts=pcall,type,tostring e.pcall=function(f,...) return p(f,...) end e.type=t e.tostring=ts " ..
        "e._G=e " ..
        "setmetatable(e,{__metatable=false,__index=function(_,k) if ban[k] then return nil end return base[k] end}) " ..
        "return e end)()"
end

-- Host debug anchor captured INSIDE the bundle's own chunk scope (the real host
-- globals), independently of the sandboxed payload environment. Identity-checked
-- by the interpreter's stride-jittered sampler.
Environment.anchor = function()
    return "(function(t) return {d=t,g=t.gethook,s=t.sethook} end)(debug)"
end

return Environment