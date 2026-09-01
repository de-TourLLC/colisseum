local source_file = debug.getinfo(1, "S").source:sub(2)
local root = source_file:match("^(.*)[/\\]tests[/\\]groups[/\\][^/\\]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
local StepPaths = require("src.core.step-paths")

local Validate = require("src.core.validate")
local source = "local value = 001.2300e+004\r\n\tlocal text = \"a  + b\"  ,  {  value  } -- keep   spaces\r\nreturn text"
local names = {
    "line-ending-policy", "protected-literal-formatting", "operator-canonicalization",
    "comment-policy", "numeric-canonicalization", "delimiter-line-policy",
    "deterministic-layout", "tab-indent-normalize", "final-newline-policy", "comma-layout"
}

for _, name in ipairs(names) do
    local step = require(StepPaths.module(name))
    assert(step.name == name and step.version == 1 and type(step.apply) == "function")
    local output = step.apply(source)
    local valid, message = Validate.syntax(output)
    assert(valid, name .. ": " .. tostring(message))
    assert(output:find("\"a  + b\"", 1, true), name .. ": changed protected literal")
    assert(output:find("-- keep   spaces", 1, true), name .. ": changed protected comment")
end

assert(require(StepPaths.module("line-ending-policy")).apply(source, { style = "crlf" }):find("\r\n", 1, true))
assert(require(StepPaths.module("numeric-canonicalization")).apply("return 001.2300e+004") == "return 1.23e4")
assert(require(StepPaths.module("tab-indent-normalize")).apply("\treturn 1", { width = 2 }) == "  return 1")
assert(require(StepPaths.module("comma-layout")).apply("return { 1 ,  2 }") == "return { 1, 2 }")
assert(require(StepPaths.module("final-newline-policy")).apply("return 1") == "return 1\n")
assert(not pcall(function() require(StepPaths.module("line-ending-policy")).apply("return (") end))
print("new token transformations: passed")
