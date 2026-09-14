-- Sandboxed VM environment and anti-hook anchor generators.

local Environment = {}

-- Emit a name as an escaped byte string ("\100\101..") so it never appears as plaintext.
local function literal(name)
    return '"' .. name:gsub(".", function(c)
        return "\\" .. string.format("%03d", c:byte())
    end) .. '"'
end

-- Names kept out of the sandbox: env accessors and code loaders. `debug` is allowed
-- through, since on Roblox it is read-only (info/traceback, no sethook) and scripts use debug.info.
local ban_names = { "getfenv", "setfenv", "loadstring", "load", "dofile", "loadfile" }
local ban_set = {}
for _, n in ipairs(ban_names) do
    ban_set[#ban_set + 1] = "[" .. literal(n) .. "]=true"
end
local ban_set_literal = "{" .. table.concat(ban_set, ",") .. "}"

-- Build the payload's global table: copy real globals in (banned names excluded), fall
-- back through a metatable for the rest, and give the payload a `_G` separate from its own writes.
Environment.expression = function()
    return "(function()" ..
        -- getfenv(0) is the live env. rawget finds it on LuaJIT; on Roblox _G is empty, so use getfenv.
        "local rg=rawget local gf=rg(_G," .. literal("getfenv") .. ") or getfenv " ..
        "local base=(type(gf)==\"function\" and gf(0)) or _G " ..
        "local ban=" .. ban_set_literal .. " " ..
        "local e={} " ..
        "for k,v in next,_G do if not ban[k] then e[k]=v end end " ..
        "for k,v in next,base do if e[k]==nil and not ban[k] then e[k]=v end end " ..
        -- Native pcall/type/tostring; a wrapped pcall reads as a Lua function under
        -- debug.info and trips audits scanning for non-native globals.
        "local p,t,ts=pcall,type,tostring e.pcall=p e.type=t e.tostring=ts " ..
        -- `g` is the payload's _G, a snapshot of builtins only. Its own writes go to `e`,
        -- so they never show up under pairs(_G).
        "local g={} for k,v in next,e do g[k]=v end " ..
        "local mt={__metatable=false,__index=function(_,k) if ban[k] then return nil end return base[k] end} " ..
        "setmetatable(e,mt) setmetatable(g,mt) e._G=g g._G=g " ..
        "return e end)()"
end

-- Snapshot of the host debug table, captured outside the sandbox for the hook sampler.
Environment.anchor = function()
    return "(function(t) return {d=t,g=t.gethook,s=t.sethook} end)(debug)"
end

return Environment