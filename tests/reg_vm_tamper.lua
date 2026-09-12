-- Interpreter-bound tamper gate: program.m arms a startup scan in reg-runtime that
-- latches the silent honeypot drift when a decisive executor/injector marker is
-- present in the host environment (or a debug hook is installed). Verifies it trips
-- on tamper, stays clean otherwise, and is a strict no-op when unarmed (no program.m).
local function project_root()
    local source = debug.getinfo(1, "S").source:sub(2)
    return source:match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."
end
local root = project_root()
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local RegCompiler = require("src.core.reg-compiler")
local RegBytecode = require("src.core.reg-bytecode")
local Runtime = require("src.core.reg-runtime")

local passed, failed = 0, 0
local function ok(cond, msg) if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: " .. msg .. "\n") end end

local proto = RegCompiler.compile("return 1000+337")
local fog = { 5, 10, 15, 20 }
local blob, regs = RegBytecode.encode_opaque(proto, fog, true)
local M = { "getgenv", "getgc", "KRNL_LOADED", "identifyexecutor" }

-- Armed + clean host -> correct.
local clean = Runtime.run({ S = blob, f = fog, r = regs, enc = true, m = M },
    { environment = setmetatable({}, { __index = _G }) })[1]
ok(clean == 1337, "armed + clean host returns correct value")

-- Armed + executor marker present -> silently wrong (drift latched).
local exploit = Runtime.run({ S = blob, f = fog, r = regs, enc = true, m = M },
    { environment = setmetatable({ getgenv = function() end }, { __index = _G }) })[1]
ok(exploit ~= 1337, "armed + executor marker latches drift (wrong result)")

-- A different decisive marker also trips.
local exploit2 = Runtime.run({ S = blob, f = fog, r = regs, enc = true, m = M },
    { environment = setmetatable({ KRNL_LOADED = true }, { __index = _G }) })[1]
ok(exploit2 ~= 1337, "second decisive marker also trips")

-- Unarmed (no program.m): never trips, even with a marker present (back-compat).
local unarmed = Runtime.run({ S = blob, f = fog, r = regs, enc = true },
    { environment = setmetatable({ getgenv = function() end }, { __index = _G }) })[1]
ok(unarmed == 1337, "unarmed build ignores markers (no false trip)")

io.write(string.format("register VM tamper gate: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
