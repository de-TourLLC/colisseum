-- LuaJIT-compatible focused tests for src.core.compiler.
local source = debug.getinfo(1, "S").source:sub(2)
local root = source:match("^(.*)[/\\]src[/\\]core[/\\][^/\\]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local Compiler = require("src.core.compiler")
local Bytecode = require("src.core.bytecode")
local Runtime = require("src.core.runtime")

local passed, failed = 0, 0
local function check(value, message) if not value then error(message, 2) end end
local function test(name, callback)
    local ok, message = xpcall(callback, debug.traceback)
    if ok then passed = passed + 1; io.stdout:write("PASS " .. name .. "\n")
    else failed = failed + 1; io.stdout:write("FAIL " .. name .. "\n" .. message .. "\n") end
end
local function fails(callback, text)
    local ok, message = pcall(callback)
    check(not ok and tostring(message):find(text, 1, true), "missing diagnostic: " .. tostring(message))
end

test("functions, loops, tables, and shadowing", function()
    local source = [[local total = 0
for i = 1, 3 do total = total + i end
local function add(value)
    local total = { value = value }
    return total.value + 1
end
return add(total)]]
    local bytecode = Compiler.compile(source)
    local values = Runtime.run(Bytecode.decode(bytecode))
    check(values[1] == 7, "unexpected execution result")
end)

test("inspection includes references and scope ids", function()
    local report = Compiler.inspect("local x = 1\ndo local x = 2 return x end\nreturn x")
    check(report.opcodes.chunk and report.last_scope_id >= 2, "missing inspection data")
    check(report.ast.scope_id == 1, "root scope id was not assigned")
end)

test("malformed and unsupported syntax have clear errors", function()
    fails(function() Compiler.compile("if true then return 1") end, "compiler: malformed input")
    fails(function() Compiler.compile("return 1 & 2") end, "compiler: unsupported-syntax")
end)

test("CLBC round trip is byte-for-byte stable", function()
    local encoded = Compiler.compile("return { answer = 42 }")
    local decoded = Bytecode.decode(encoded)
    check(Bytecode.encode(decoded) == encoded, "CLBC round trip changed bytes")
end)

io.stdout:write("\nResults: " .. passed .. " passed, " .. failed .. " failed\n")
if failed > 0 then os.exit(1) end
