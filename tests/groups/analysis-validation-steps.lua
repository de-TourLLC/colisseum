local source_file = debug.getinfo(1, "S").source:sub(2)
local root = source_file:match("^(.*)[/\\]tests[/\\]groups[/\\][^/\\]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
local StepPaths = require("src.core.step-paths")

local names = {
    "delimiter-validation", "string-termination-validation", "numeric-validity-validation",
    "function-budget-analysis", "literal-budget-analysis", "comment-budget-analysis",
    "global-access-report", "dynamic-feature-guard", "operator-usage-report", "line-length-analysis"
}
local source = "local value = 2\nfunction add(x) return x + value + math.floor(1.5) end\n-- note\nreturn add(3)"

for _, name in ipairs(names) do
    local step = require(StepPaths.module(name))
    assert(step.name == name and step.version == 1)
    assert(step.apply(source) == source)
    assert(step.last_metadata and step.last_metadata.validated == true)
end

assert(require(StepPaths.module("delimiter-validation")).apply("return ({1})"))
assert(not pcall(function() require(StepPaths.module("delimiter-validation")).apply("return (1") end))
assert(not pcall(function() require(StepPaths.module("string-termination-validation")).apply("return 'unfinished") end))
assert(not pcall(function() require(StepPaths.module("numeric-validity-validation")).apply("return 1e") end))
assert(not pcall(function() require(StepPaths.module("function-budget-analysis")).apply("function a() end\nfunction b() end", { max_functions = 1 }) end))
assert(not pcall(function() require(StepPaths.module("comment-budget-analysis")).apply("-- one\n-- two", { max_comments = 1 }) end))
assert(not pcall(function() require(StepPaths.module("dynamic-feature-guard")).apply("return load('x')") end))
assert(require(StepPaths.module("global-access-report")).last_metadata.globals[1] == "math")
assert(require(StepPaths.module("operator-usage-report")).last_metadata.operator_counts["+"] == 2)
assert(require(StepPaths.module("line-length-analysis")).apply("return 123", { max_length = 20 }))

print("analysis and validation steps: passed")
