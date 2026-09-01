-- Adversarial regression tests for parser, bytecode, runtime, CLI, and packaging.
local source = debug.getinfo(1, "S").source:sub(2)
local root = source:match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
local StepPaths = require("src.core.step-paths")

local Lexer = require("src.core.lexer")
local Rename = require(StepPaths.module("rename"))
local Bytecode = require("src.core.bytecode")
local Obfuscator = require("src.obfuscator")
local Package = require("src.core.luau-package")

local passed, failed = 0, 0

local function check(condition, message)
    if not condition then error(message or "condition failed", 2) end
end

local function equal(actual, expected, message)
    check(actual == expected, (message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function fails(callback, fragment)
    local ok, message = pcall(callback)
    check(not ok, "expected an error")
    if fragment then
        check(tostring(message):find(fragment, 1, true) ~= nil,
            "error did not contain '" .. fragment .. "': " .. tostring(message))
    end
end

local function test(name, callback)
    local ok, message = xpcall(callback, debug.traceback)
    if ok then
        passed = passed + 1
        io.stdout:write("PASS " .. name .. "\n")
    else
        failed = failed + 1
        io.stdout:write("FAIL " .. name .. "\n" .. tostring(message) .. "\n")
    end
end

test("rename preserves shadowing, parameters, and member names", function()
    local input = [[
local value = "outer"
local record = { value = value }
local function decorate(value)
    local value = value .. "!"
    do
        local value = "block"
        record.value = value
    end
    return value
end
return value, record.value, decorate(value), record.value
]]
    local output = Rename.apply(input, { seed = 77 })
    check(output:find(".value", 1, true) ~= nil, "member name was renamed")
    local chunk = assert(loadstring(output))
    local outer, member_before, decorated, member_after = chunk()
    equal(outer, "outer", "outer binding")
    equal(member_before, "outer", "field initializer")
    equal(decorated, "outer!", "parameter binding")
    equal(member_after, "block", "nested shadow binding")
end)

test("rename keeps self-referential local initializers pointing at the outer binding", function()
    -- `local x = x` binds a NEW local x whose initializer reads the OUTER/global x.
    -- The RHS must not be renamed to the still-nil new local, or the localized
    -- global (a common idiom: `local print = print`) becomes nil and later calls
    -- crash. Exercised in combination with a preceding loop and multi-name lists,
    -- which is where the initializer-end detection previously mis-fired.
    local cases = {
        { "local print = print print(1) return 41 + 1", 42 },
        { "local a = 1 local a = a + 1 return a", 2 },
        { "local n = 5 local n = n * 2 return n", 10 },
        { "local c = 0 repeat c = c + 1 until c == 5 local p = print p(c) return c", 5 },
        { "local p, q = print, tostring return q(7)", "7" },
    }
    for _, case in ipairs(cases) do
        local output = Rename.apply(case[1], { seed = 3 })
        local chunk = assert(loadstring(output), "rename produced invalid Lua for: " .. case[1])
        equal(chunk(), case[2], "self-ref initializer: " .. case[1])
    end
end)

test("lexer keeps long strings and comments opaque at large sizes", function()
    local payload = string.rep("identifier_should_not_be_renamed ", 2048)
    local input = "--[=[" .. payload .. "]=]\nlocal text = [=[" .. payload .. "]=]\nreturn text"
    local tokens = Lexer.scan(input)
    equal(tokens[1].kind, "comment")
    equal(tokens[2].kind, "identifier")
    equal(tokens[5].kind, "string")
    equal(#tokens[5].value, #payload + 6, "long string length")
    local output = Rename.apply(input, { seed = 12 })
    check(output:find(payload, 1, true) ~= nil, "long content changed")
    local result = assert(loadstring(output))()
    equal(result, payload, "long string value")
end)

test("bytecode rejects forward and invalid instruction references", function()
    local opcode = Bytecode.opcode
    local function program(reference)
        return {
            root = 2,
            instructions = {
                { opcode = opcode("number"), operands = { 1 } },
                { opcode = opcode("return"), operands = { 1, { ref = reference } } }
            }
        }
    end
    fails(function() Bytecode.validate(program(2)) end, "forward or invalid reference")
    fails(function() Bytecode.validate(program(0)) end, "forward or invalid reference")
    fails(function() Bytecode.validate(program(99)) end, "forward or invalid reference")
end)

test("runtime enforces step, loop, depth, and option limits", function()
    fails(function() Obfuscator.execute("while true do end", { steps = 8 }) end, "step limit exceeded")
    fails(function() Obfuscator.execute("while true do end", { loop_iterations = 3 }) end, "loop iteration limit exceeded")
    local recursive = "local function recurse() return recurse() end\nreturn recurse()"
    fails(function() Obfuscator.execute(recursive, { depth = 8, steps = 1000 }) end, "evaluation depth limit exceeded")
    fails(function() Obfuscator.execute("return 1", { steps = 0 }) end, "steps must be an integer")
    fails(function() Obfuscator.execute("return 1", { depth = 1.5 }) end, "depth must be an integer")
end)

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local value = file:read("*a")
    file:close()
    return value
end

local function shell_quote(path)
    return '"' .. path:gsub('"', '""') .. '"'
end

-- Run the CLI with the same Lua executable that runs this suite.  The CI job
-- installs LuaJIT, which does not necessarily provide a separate `lua` alias.
local function current_lua()
    return (arg and arg[-1]) or "luajit"
end

test("CLI rejects missing required arguments", function()
    local cases = {
        { command = "", fragment = "usage:" },
        { command = "--preset", fragment = "missing value for --preset" },
        { command = "--preset Easy --out", fragment = "missing value for --out" }
    }
    for _, case in ipairs(cases) do
        local capture = (os.tmpname():match("[^/\\]+$") or "colisseum_cli_capture")
        local invocation = shell_quote(current_lua()) .. " " .. shell_quote(root .. "/cli.lua") .. " " .. case.command ..
            " > " .. shell_quote(capture) .. " 2>&1"
        -- Windows' command processor needs an extra outer quote when the first
        -- command is a quoted executable path; POSIX shells do not.
        local command = package.config:sub(1, 1) == "\\" and
            ('cmd /d /s /c "' .. invocation .. '"') or invocation
        local status = os.execute(command)
        local text = read_file(capture)
        os.remove(capture)
        check(status ~= true and status ~= 0, "CLI unexpectedly succeeded for: " .. case.command)
        check(text:find(case.fragment, 1, true) ~= nil,
            "CLI output did not contain '" .. case.fragment .. "' for: " .. case.command)
    end
end)

test("secure package reconstructs bytecode across chunk boundaries", function()
    local bytes = {}
    for index = 0, 1024 do bytes[#bytes + 1] = string.char(index % 256) end
    local expected = table.concat(bytes)
    local fiu = [[
return {
    luau_newsettings = function() return {} end,
    luau_load = function(bytecode)
        return function() return bytecode end, function() end
    end
}
]]
    local loader = Package.build(expected, fiu)
    local result = assert(loadstring(loader))()
    equal(#result, #expected, "reconstructed bytecode length")
    check(result == expected, "reconstructed bytecode differs")
    check(loader:find("coli_", 1, true) ~= nil,
        "secure package must embed the per-build renamed VM decryptor")
    check(loader:find(",16)", 1, true) ~= nil and loader:find(",12)", 1, true) ~= nil,
        "secure package must run the ChaCha quarter-round")
    check(loader:find("_j=function", 1, true) == nil and loader:find("__fiu", 1, true) == nil,
        "secure package must carry no fixed, scannable marker names")
    check(loader:find("loadstring", 1, true) == nil,
        "secure package must never use loadstring")
    local plaintext_prefix = {}
    for index = 1, 12 do plaintext_prefix[index] = tostring(expected:byte(index)) end
    check(loader:find("{" .. table.concat(plaintext_prefix, ","), 1, true) == nil,
        "secure package must not embed bytecode as plaintext")
end)

io.stdout:write("\nResults: " .. passed .. " passed, " .. failed .. " failed\n")
if failed > 0 then os.exit(1) end
