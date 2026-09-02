-- LuaJIT-compatible regression runner for Colisseum.
local function project_root()
    local source = debug.getinfo(1, "S").source:sub(2)
    return source:match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."
end

local root = project_root()
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local Lexer = require("src.core.lexer")
local Parser = require("src.core.parser")
local Ast = require("src.core.ast")
local Scope = require("src.core.scope")
local References = require("src.core.references")
local Bytecode = require("src.core.bytecode")
local Runtime = require("src.core.runtime")
local Obfuscator = require("src.obfuscator")
local LuauTypes = require("src.core.luau-type-erase")

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
    if fragment then check(tostring(message):find(fragment, 1, true) ~= nil, "error did not contain '" .. fragment .. "': " .. tostring(message)) end
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

test("lexer tokenizes comments, strings, numbers, and operators", function()
    local tokens = Lexer.scan("-- comment\nlocal text = [[hello]] .. \"world\" // 2 ...")
    equal(#tokens, 11, "token count")
    equal(tokens[1].kind, "comment")
    equal(tokens[2].value, "local")
    equal(tokens[4].value, "=")
    equal(tokens[5].kind, "string")
    check(tokens[5].protected, "long string should be protected")
    equal(tokens[6].value, "..")
    equal(tokens[7].value, "\"world\"")
    equal(tokens[8].value, "/")
    equal(tokens[9].value, "/")
    equal(tokens[10].kind, "number")
    equal(tokens[11].value, "...")
    local tail = Lexer.scan("...")
    equal(tail[1].value, "...")
end)

test("parser builds an AST with precedence and control flow", function()
    local ast = Parser.parse([[local total = 1 + 2 * 3
if total > 3 then
    total = total + 1
end
return total]])
    equal(ast.kind, "chunk")
    equal(#ast.body, 3, "statement count")
    equal(ast.body[1].kind, "local")
    equal(ast.body[1].values[1].kind, "binary")
    equal(ast.body[1].values[1].right.operator, "*")
    equal(ast.body[2].kind, "if")
    equal(ast.body[3].kind, "return")
    local valid, message = Ast.validate(ast)
    check(valid, message)
    local scopes, last_id = Ast.assign_scope_ids(ast)
    check(scopes[1] == ast and last_id >= 2, "scope ids were not assigned")
end)

test("scope analysis tracks locals, parameters, and references", function()
    local ast = Parser.parse([[local value = 3
function twice(number)
    return number + value
end
return value]])
    local scope = Scope.analyze(ast)
    check(scope.kind == "root" and #scope.children == 1, "root block missing")
    local block = scope.children[1]
    check(block.symbols.value and block.symbols.value.references == 2, "local reference count is wrong")
    check(block.symbols.twice and block.symbols.twice.kind == "function", "function declaration missing")
    local references = References.analyze(ast)
    check(references.symbols.value and references.symbols.value[1].references_count == 2, "reference analysis missed a use")
    check(ast.body[2].body[1].values[1].left.binding ~= nil, "function parameter was not bound")
end)

test("bytecode compiles, validates, inspects, and round-trips", function()
    local ast = Obfuscator.parse("local answer = 6 * 7\nreturn answer")
    local program = Bytecode.compile(ast)
    check(Bytecode.validate(program), "compiled program is invalid")
    local encoded = Bytecode.encode(program)
    check(encoded:sub(1, 4) == Bytecode.MAGIC, "missing bytecode magic")
    local decoded = Bytecode.decode(encoded)
    local inspection = Runtime.inspect(decoded)
    equal(inspection.version, Bytecode.VERSION)
    check(inspection.opcodes.chunk and inspection.opcodes.binary, "inspection did not count opcodes")
    fails(function() Bytecode.decode("bad") end, "bad magic")
    fails(function() Bytecode.validate({ instructions = {}, root = 0 }) end, "instruction limit")
end)

test("runtime executes locals, closures, tables, and loops", function()
    local source = [[local total = 0
for index = 1, 4 do
    total = total + index
end
local function add(value)
    return value + total
end
return add(2)]]
    local values, stats = Obfuscator.execute(source, { steps = 500, loop_iterations = 20 })
    equal(values[1], 12, "runtime result")
    check(stats.steps > 0 and stats.loop_iterations == 4, "runtime statistics are wrong")
    local table_values = Obfuscator.execute("local item = {name = 9}\nreturn item.name")
    equal(table_values[1], 9, "member access result")
    fails(function() Obfuscator.execute("while true do end", { steps = 20 }) end, "step limit exceeded")
end)

test("rename clears the stale self-reference guard between declarations", function()
    -- `local length;` (no initializer) must not leave `length` in the
    -- per-statement self-reference guard, or a LATER statement's RHS resolves it
    -- to the outer scope and leaves a dangling global (the embedded VM decoder
    -- used to crash with "arithmetic on global 'length'").
    local Rename = require("src.steps.naming.rename")
    local decoded = "local function read(n, data, pos) local length; length, pos = read_u(data, pos, 2); if length == 0 or pos + length - 1 > n then return nil end; local text = data:sub(pos, pos + length - 1); return text, pos + length end"
    local renamed = Rename.apply(decoded, { seed = "regression" })
    check(not renamed:find("length", 1, true), "rename left a stale `length` reference")
    local chunk = loadstring(renamed, "renamed")
    check(chunk ~= nil, "renamed snippet did not load")
end)

test("native VMs erase Luau type metadata before compiling", function()
    local source = [[
export type Counter = { value: number }
local function add(left: number, right: number): number
    return (left :: number) + right
end
local item: Counter = { value = add(19, 23) }
return item.value
]]
    local erased = LuauTypes.erase(source)
    check(not erased:find("export type", 1, true), "type alias survived erasure")
    check(not erased:find("::", 1, true), "type assertion survived erasure")
    local chunk, load_error = loadstring(erased)
    check(chunk ~= nil, "erased Luau did not load as Lua: " .. tostring(load_error))
    local values = Obfuscator.execute(source)
    equal(values[1], 42, "native compiler changed typed Luau semantics")
local fortress = Obfuscator.obfuscate(source, { preset = "fortress", target = "luau", seed = 42 })
    check(type(fortress) == "string" and #fortress > 0, "Fortress produced no register-VM output")
    check(not fortress:find("export type", 1, true), "Fortress retained a type alias")
    check(fortress:find("loadstring", 1, true) == nil, "Fortress must not use loadstring")
    local fchunk, ferror = loadstring(fortress, "fortress-vm")
    check(fchunk ~= nil, "Fortress output did not load: " .. tostring(ferror))
    local fok, fresult = pcall(fchunk)
    check(fok and fresult == 42, "Fortress changed register-VM semantics: " .. tostring(fresult))
end)

test("text presets produce valid executable LuaJIT output", function()
    local source = "local value = 40 + 2\nreturn value"
    -- Text-based presets stay runnable anywhere Lua/LuaJIT runs.
    local names = { "easy", "medium", "hard", "full", "secure" }
    for _, name in ipairs(names) do
        local output = Obfuscator.obfuscate(source, { preset = name, target = "lua" })
        check(type(output) == "string" and #output > 0, name .. " preset produced no output")
        local valid, message = require("src.core.validate").syntax(output)
        check(valid, name .. " preset produced invalid syntax: " .. tostring(message))
        local chunk, load_error = loadstring(output)
        check(chunk ~= nil, name .. " preset did not load: " .. tostring(load_error))
        local ok, result = pcall(chunk)
        check(ok and result == 42, name .. " preset changed runtime result: " .. tostring(result))
    end
end)

test("total preset produces an encrypted Fiu-VM output with no loadstring", function()
    -- total compiles to ChaCha-encrypted Luau bytecode run by the embedded Fiu VM.
    -- Its output targets Luau/Roblox (not LuaJIT), so verify structure, not execution.
    local output = Obfuscator.obfuscate("local zqUniqueMarker9137 = 40 + 2\nreturn zqUniqueMarker9137",
        { preset = "total", target = "luau" })
    check(type(output) == "string" and #output > 0, "total preset produced no output")
    check(output:find("loadstring", 1, true) == nil, "total preset must not use loadstring")
    check(output:find("coli_", 1, true) ~= nil, "total preset must embed the per-build renamed VM")
    check(output:find("__fiu", 1, true) == nil, "total preset must carry no fixed scannable marker names")
    check(output:find("zqUniqueMarker9137", 1, true) == nil, "total preset must not leave the source in plaintext")
end)

io.stdout:write("\nResults: " .. passed .. " passed, " .. failed .. " failed\n")
if failed > 0 then os.exit(1) end
