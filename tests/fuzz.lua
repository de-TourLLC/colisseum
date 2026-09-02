-- Deterministic, LuaJIT-compatible robustness harness.
-- Generated text is passed only to the lexer/parser. It is never loaded or run.
local source = debug.getinfo(1, "S").source:sub(2)
local root = source:match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local Lexer = require("src.core.lexer")
local Parser = require("src.core.parser")
local Bytecode = require("src.core.bytecode")
local Runtime = require("src.core.runtime")

local SEED = 0x13579B
local SOURCE_CASES = 96
local BYTECODE_CASES = 96
local RUNTIME_CASES = 64
local MAX_INPUT = 192
local state = SEED
local passed, failed, total = 0, 0, 0
local category_totals, category_failures = {}, {}

local function random(limit)
    -- The modulus keeps this exact on LuaJIT and stock Lua numbers.
    state = (state * 48271) % 2147483647
    return state % limit
end

local function random_text(maximum)
    local alphabet = " abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-*/%(){}[];,.:=<>~\n\t'\"\\"
    local length = random(maximum + 1)
    local result = {}
    for index = 1, length do
        local position = random(#alphabet) + 1
        result[index] = alphabet:sub(position, position)
    end
    return table.concat(result)
end

local function u32(value)
    return string.char(
        math.floor(value / 16777216) % 256,
        math.floor(value / 65536) % 256,
        math.floor(value / 256) % 256,
        value % 256
    )
end

local function u16(value)
    return string.char(math.floor(value / 256) % 256, value % 256)
end

local function header(version, flags, count, root_id)
    return "CLBC" .. string.char(version, flags) .. u32(count) .. u32(root_id)
end

local function classify_error(message, prefix)
    return type(message) == "string" and message:find(prefix, 1, true) ~= nil
end

local function record(category, name, callback)
    total = total + 1
    category_totals[category] = (category_totals[category] or 0) + 1
    local ok, result = pcall(callback)
    local passed_case = ok or classify_error(result, "lexer:") or classify_error(result, "parser:") or
        classify_error(result, "bytecode:") or classify_error(result, "runtime:")
    if passed_case then
        passed = passed + 1
    else
        failed = failed + 1
        category_failures[category] = (category_failures[category] or 0) + 1
        io.stdout:write("FAIL " .. category .. "/" .. name .. ": " .. tostring(result) .. "\n")
    end
end

local function assert_rejected(name, data, limits)
    record("malformed-bytecode", name, function()
        local ok, message = pcall(Bytecode.decode, data, limits)
        if ok or not classify_error(message, "bytecode:") then error("unexpected decoder result bih: " .. tostring(message)) end
    end)
end

for index = 1, SOURCE_CASES do
    local text = random_text(MAX_INPUT)
    record("lexer", tostring(index), function()
        local tokens = Lexer.scan(text)
        if type(tokens) ~= "table" then error("lexer returned a non-table") end
        if #text > MAX_INPUT then error("lexer input bound exceeded") end
    end)
    record("parser", tostring(index), function()
        local ok, result = pcall(Parser.parse, text)
        if not ok and not classify_error(result, "parser:") and not classify_error(result, "lexer:") then
            error(result)
        end
    end)
end

for index = 1, BYTECODE_CASES do
    local count = random(21)
    local data = header(2, 0, count, random(21))
    for instruction = 1, count do
        data = data .. u16(random(70000)) .. u16(random(21)) .. random_text(12)
    end
    if #data > MAX_INPUT then data = data:sub(1, MAX_INPUT) end
    record("bytecode", tostring(index), function()
        local ok, message = pcall(Bytecode.decode, data, { bytes = MAX_INPUT, instructions = 32, operands = 16 })
        if not ok and not classify_error(message, "bytecode:") then error(message) end
    end)
end

assert_rejected("bad-magic", "NOPE")
assert_rejected("truncated-header", "CLBC")
assert_rejected("version", header(1, 0, 1, 1))
assert_rejected("flags", header(2, 1, 1, 1))
assert_rejected("zero-count", header(2, 0, 0, 0))
assert_rejected("unknown-opcode", header(2, 0, 1, 1) .. u16(65535) .. u16(0))
assert_rejected("truncated-instruction", header(2, 0, 1, 1) .. u16(1))
assert_rejected("operand-limit", header(2, 0, 1, 1) .. u16(Bytecode.opcode("chunk")) .. u16(17))
assert_rejected("trailing-bytes", Bytecode.encode({
    root = 1,
    instructions = {{ opcode = Bytecode.opcode("chunk"), operands = { 0 } }}
}) .. "x")
assert_rejected("byte-limit", "CLBC", { bytes = 3 })

local finite_program = Bytecode.compile(Parser.parse("return 1 + 2"))
local loop_program = Bytecode.compile(Parser.parse("while true do end"))
for index = 1, RUNTIME_CASES do
    local options = { steps = random(12) + 1, depth = random(12) + 1, loop_iterations = random(12) + 1 }
    record("runtime", tostring(index), function()
        local ok, message = pcall(Runtime.run, finite_program, options)
        if not ok and not classify_error(message, "runtime:") then error(message) end
    end)
end

record("runtime-limits", "step", function()
    local ok, message = pcall(Runtime.run, loop_program, { steps = 3, depth = 8, loop_iterations = 8 })
    if ok or not classify_error(message, "runtime: step limit exceeded") then error("step limit was not enforced") end
end)
record("runtime-limits", "loop", function()
    local ok, message = pcall(Runtime.run, loop_program, { steps = 100, depth = 8, loop_iterations = 3 })
    if ok or not classify_error(message, "runtime: loop iteration limit exceeded") then error("loop limit was not enforced") end
end)
record("runtime-limits", "invalid-options", function()
    local ok, message = pcall(Runtime.run, finite_program, { steps = 0 })
    if ok or not classify_error(message, "runtime: steps must be an integer") then error("invalid limit was accepted") end
end)

io.stdout:write("\nFuzz seed: " .. SEED .. "\n")
io.stdout:write("Fuzz cases: " .. total .. "\n")
for _, category in ipairs({ "lexer", "parser", "bytecode", "malformed-bytecode", "runtime", "runtime-limits" }) do
    io.stdout:write(category .. ": " .. (category_totals[category] or 0) .. " passed, " ..
        (category_failures[category] or 0) .. " failed\n")
end
io.stdout:write("Results: " .. passed .. " passed, " .. failed .. " failed\n")
if failed > 0 then os.exit(1) end
