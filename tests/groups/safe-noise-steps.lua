local source_file = debug.getinfo(1, "S").source:sub(2)
local root = source_file:match("^(.*)[/\\]tests[/\\]groups[/\\][^/\\]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
local StepPaths = require("src.core.step-paths")

local Validate = require("src.core.validate")
local Lexer = require("src.core.lexer")
local source = [[local function calculate(value)
    local flag = value > 2
    if flag then return value + 3 else return value - 3 end
end
return calculate(7), coroutine.status(coroutine.running())]]

local function tokens(value)
    local result = {}
    for _, token in ipairs(Lexer.scan(value)) do result[#result + 1] = token.kind .. ":" .. token.value end
    return result
end

source = source:gsub(", coroutine%.status%(coroutine%.running%(%)%)", "")
local original = assert(loadstring(source))
local ok, first = pcall(original)
assert(ok and first == 10)

for _, name in ipairs({ "garbage-code", "table-noise", "boolean-noise", "visual-noise" }) do
    local step = require(StepPaths.module(name))
    local output = step.apply(source)
    local valid, message = Validate.syntax(output)
    assert(valid, message)
    local chunk, load_error = loadstring(output)
    assert(chunk, load_error)
    local run_ok, value, state = pcall(chunk)
    assert(run_ok and value == first, name .. " changed runtime behavior")
    assert(step.last_metadata.validated == true)
end

local visual = require(StepPaths.module("visual-noise")).apply(source)
local before, after = tokens(source), tokens(visual)
assert(#before == #after)
for index = 1, #before do assert(before[index] == after[index]) end

local boolean = require(StepPaths.module("boolean-noise")).apply("return true, false, 'true' -- false")
assert(boolean:find("(true and true)", 1, true) and boolean:find("(false or false)", 1, true))
assert(require(StepPaths.module("table-noise")).apply("#!/usr/bin/env luajit\nreturn 1"):match("^#![^\n]*\n") == "#!/usr/bin/env luajit\n")

local guard = require(StepPaths.module("coroutine-integrity-guard"))
local coroutine_source = source .. "\nreturn coroutine.status(coroutine.running())"
assert(guard.apply(coroutine_source) == coroutine_source)
assert(guard.last_metadata.analysis_only and guard.last_metadata.runtime_behavior_untouched)
assert(not pcall(function() guard.apply("return (", { max_tokens = 2 }) end))
assert(not pcall(function() require(StepPaths.module("garbage-code")).apply(source, { max_bytes = 0 }) end))

print("safe noise steps: passed")
