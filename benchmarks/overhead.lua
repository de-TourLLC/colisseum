--[[
    Runtime overhead of the register VM vs native, on a fixed compute kernel -- the
    factor that says how much the protection slows a script's own logic. (Build-time
    cost is measured in presets.lua.)
]]

local RegVM = require("src.core.reg-vm")
local loadfn = loadstring or load

local KERNEL = [[
local s = 0
for i = 1, 3000 do
    s = (s + i * 3) % 100003
    if i % 7 == 0 then s = s + i end
end
return s
]]

local function time(iterations, fn)
    for _ = 1, 2 do fn() end
    collectgarbage("collect")
    local started = os.clock()
    local r
    for _ = 1, iterations do r = fn() end
    return (os.clock() - started) * 1000 / iterations, r
end

local function run()
    print("Runtime overhead (register VM vs native)")
    print(string.rep("-", 42))
    local native = assert(loadfn("return (function() " .. KERNEL .. " end)()"))
    local proto = RegVM.compile(KERNEL)

    local cached = RegVM.opaque(proto); cached.kc = 1
    local nat_ms, nat = time(200, native)
    local vm_ms, vm = time(200, function() return RegVM.run(proto)[1] end)
    local kc_ms, kv = time(200, function()
        local RegRuntime = require("src.core.reg-runtime")
        return RegRuntime.run(cached)[1]
    end)

    assert(nat == vm and nat == kv, "overhead kernel mismatch: native=" .. tostring(nat) .. " vm=" .. tostring(vm) .. " cached=" .. tostring(kv))
    print(string.format("%-28s %8.4f ms/op", "native (loadstring)", nat_ms))
    print(string.format("%-28s %8.4f ms/op  (%.0fx)", "register VM", vm_ms, nat_ms > 0 and vm_ms / nat_ms or 0))
    print(string.format("%-28s %8.4f ms/op  (%.0fx)", "register VM + --cache", kc_ms, nat_ms > 0 and kc_ms / nat_ms or 0))
    print("(all return " .. tostring(nat) .. ")")
end

return run
