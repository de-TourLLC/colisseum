local source_file = debug.getinfo(1, "S").source:sub(2)
local root = source_file:match("^(.*)[/\\]tests[/\\]groups[/\\][^/\\]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
local StepPaths = require("src.core.step-paths")

local Validate = require("src.core.validate")
local names = {
    "identifier-case-normalize",
    "numeric-base-normalize",
    "operator-spacing-normalize",
    "newline-normalize",
    "delimiter-normalize"
}

local source = "local x=0007+2\r\n-- keep   spaces\r\nlocal s=\"a  + b\"\r\nreturn ({x,s})"
for _, name in ipairs(names) do
    local step = require(StepPaths.module(name))
    local output = step.apply(source)
    assert(Validate.syntax(output))
    assert(output:find("-- keep   spaces", 1, true))
    assert(output:find("a  + b", 1, true))
end

local numeric = require(StepPaths.module("numeric-base-normalize")).apply(source)
assert(numeric:find("x=7", 1, true))
local operators = require(StepPaths.module("operator-spacing-normalize")).apply("return 1+2*3")
assert(operators == "return 1 + 2 * 3")
local delimiters = require(StepPaths.module("delimiter-normalize")).apply("return ({ x , y })")
assert(delimiters == "return ({x, y})")
local newline = require(StepPaths.module("newline-normalize")).apply("return 'a\r\nb'")
assert(newline == "return 'a\r\nb'")
assert(not pcall(function() names[1] = require(StepPaths.module(names[1])).apply("return (") end))

print("token-safe steps: passed")
