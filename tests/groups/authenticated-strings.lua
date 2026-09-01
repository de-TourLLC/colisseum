local source_file = debug.getinfo(1, "S").source:sub(2)
local root = source_file:match("^(.*)[/\\]tests[/\\]groups[/\\][^/\\]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
local StepPaths = require("src.core.step-paths")

local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")
local Step = require(StepPaths.module("authenticated-strings"))

local source = "local text = 'hello\\nworld' -- 'comment'\nlocal long = [[keep 'this']]\nreturn text, long"
local output = Step.apply(source, { seed = "build-1", maxBytes = 10000 })
local valid, message = Validate.syntax(output)
assert(valid, message)
assert(output:find("-- 'comment'", 1, true))
assert(output:find("[[keep 'this']]", 1, true))
assert(Step.last_metadata.transformed == 1 and Step.last_metadata.validated)
assert(Step.metadata.limitation:find("not cryptographic authenticity", 1, true))
assert(not output:find("load", 1, true) and not output:find("loadstring", 1, true))

local chunk, load_error = loadstring(output)
assert(chunk, load_error)
local ok, text, long = pcall(chunk)
assert(ok and text == "hello\nworld" and long == "keep 'this'")

local tampered = output:gsub("hello", "hullo", 1)
local tampered_chunk = assert(loadstring(tampered))
local tampered_ok = pcall(tampered_chunk)
assert(not tampered_ok, "tampered literal must fail the fallback integrity check")

_G.__COLISSEUM_VERIFY_STRING = function(value, tag, index)
    return value == "hello\nworld" and type(tag) == "number" and index == 4
end
local hooked_output = Step.apply(source, { seed = "build-1", hostVerifier = "__COLISSEUM_VERIFY_STRING", maxBytes = 10000 })
local hooked = assert(loadstring(hooked_output))
local hooked_ok, hooked_text = pcall(hooked)
assert(hooked_ok and hooked_text == "hello\nworld")
_G.__COLISSEUM_VERIFY_STRING = nil

assert(not pcall(function() Step.apply("return '123456'", { maxPayloadBytes = 3 }) end))
assert(not pcall(function() Step.apply("return 'x'", { maxBytes = 1 }) end))
assert(not pcall(function() Step.apply("return 'x'", { hostVerifier = "bad-name" }) end))

for _, token in ipairs(Lexer.scan(output)) do
    if token.kind == "comment" then assert(token.protected) end
end
print("authenticated-strings: passed")
