-- Sandboxed VM environment + anti-hook anchor generators. `expression()` returns
-- a sandbox-table source snapshot (debug/load*/getfenv absent); `anchor()` returns
-- a host debug snapshot for the interpreter's sampler. Details kept terse.

local Environment = {}

-- Escaped string literal (every byte as \ddd) so the emitted bundle never
-- carries a scannable plaintext name like "loadstring" or "debug".
local function literal(name)
    return '"' .. name:gsub(".", function(c)
        return "\\" .. string.format("%03d", c:byte())
    end) .. '"'
end

-- Names hidden from the sandbox: env accessors and code loaders. `debug` is NOT
-- hidden: on Roblox it only exposes safe read-only introspection (debug.info,
-- debug.traceback, debug.profilebegin -- there is no sethook/gethook), and many
-- legitimate payloads (anti-tamper loaders, error reporters) call debug.info, so
-- masking it broke them with "debug_info_missing"/nil-debug errors. The VM's own
-- anti-hook anchor captures the real `debug` OUTSIDE this sandbox, so leaving it
-- visible to the payload does not weaken the interpreter's tamper detection.
-- Emitted as a SET literal `{[name]=true,...}` (escaped bytes, no plaintext) for
-- O(1) masking in both the copy loop and the __index fallback.
local ban_names = { "getfenv", "setfenv", "loadstring", "load", "dofile", "loadfile" }
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
        -- `base` must be the REAL global environment. On LuaJIT/standalone Luau `_G`
        -- IS that table, but on Roblox `_G` is a SEPARATE, initially-EMPTY shared
        -- table, so `rawget(_G,"getfenv")` is nil there -- falling back to `_G` would
        -- leave `base` empty and every payload global would resolve to nil ("attempt
        -- to call a nil value"). Fall back to the real `getfenv` global (present on
        -- Roblox even though it is absent from `_G`) so `gf(0)` yields the live env.
        "local rg=rawget local gf=rg(_G," .. literal("getfenv") .. ") or getfenv " ..
        "local base=(type(gf)==\"function\" and gf(0)) or _G " ..
        "local ban=" .. ban_set_literal .. " " ..
        "local e={} " ..
        "for k,v in next,_G do if not ban[k] then e[k]=v end end " ..
        "for k,v in next,base do if e[k]==nil and not ban[k] then e[k]=v end end " ..
        -- Bind pcall/type/tostring to their native values. `pcall` used to be wrapped
        -- in a Lua closure, but that made `debug.info(pcall,"s")` report a Lua source
        -- instead of "[C]", tripping anti-tamper audits that scan for non-native
        -- functions ("lua_function_in__G_pcall"). The native pcall is safe here.
        "local p,t,ts=pcall,type,tostring e.pcall=p e.type=t e.tostring=ts " ..
        -- Keep `_G` SEPARATE from the payload's global environment, like real Roblox
        -- (a script's own globals live in its env; `_G` is a distinct, mostly-empty
        -- shared table). `g` snapshots the sandbox's builtins, so the integrity guard
        -- still finds type/pcall/error/tostring under `_G`, but the payload's OWN
        -- global writes land in `e` (the env, where SETGLOBAL points) and never show
        -- up under `pairs(_G)`. That is what tripped anti-tamper audits scanning `_G`
        -- for the script's own functions ("lua_function_in__G_<name>"). Both tables
        -- share the ban/base `__index`, so every lookup still resolves as before.
        "local g={} for k,v in next,e do g[k]=v end " ..
        "local mt={__metatable=false,__index=function(_,k) if ban[k] then return nil end return base[k] end} " ..
        "setmetatable(e,mt) setmetatable(g,mt) e._G=g g._G=g " ..
        "return e end)()"
end

-- Host debug anchor captured INSIDE the bundle's own chunk scope (the real host
-- globals), independently of the sandboxed payload environment. Identity-checked
-- by the interpreter's stride-jittered sampler.
Environment.anchor = function()
    return "(function(t) return {d=t,g=t.gethook,s=t.sethook} end)(debug)"
end

return Environment