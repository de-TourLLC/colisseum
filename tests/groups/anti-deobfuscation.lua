local source_file = debug.getinfo(1, "S").source:sub(2)
local root = source_file:match("^(.*)[/\\]tests[/\\]groups[/\\][^/\\]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
local StepPaths = require("src.core.step-paths")

local Validate = require("src.core.validate")
local Step = require(StepPaths.module("anti-deobfuscation"))

local source = "#!/usr/bin/env luajit\nlocal value = 40\ndo\n    local unused = 0\nend\nfunction add(number)\n    return number + value\nend\nreturn add(2)\n"
local output = Step.apply(source, { seed = "group", density = 1, maxTripwires = 3, maxBytes = 1000 })

assert(Step.name == "anti-deobfuscation" and Step.version == 2)
assert(Step.metadata.description:match("^[A-Z]"))
assert(output:match("^#!/usr/bin/env luajit\n"))
assert(select(2, output:gsub("if false then", "")) == Step.last_metadata.tripwire_count)
assert(Step.last_metadata.tripwire_count == 3)
assert(Step.last_metadata.generated_bytes <= 1000)
assert(Validate.syntax(output))

local chunk, load_error = loadstring(output)
assert(chunk, load_error)
local ok, value = pcall(chunk)
assert(ok and value == 42, tostring(value))

local protected = "local text = [[if false then end]] -- if false then\nreturn text"
local protected_output = Step.apply(protected, { maxTripwires = 1 })
assert(protected_output:find("[[if false then end]]", 1, true))
assert(protected_output:find("-- if false then", 1, true))

assert(not pcall(function() Step.apply("local value = (") end))
local tiny = Step.apply("return 1", { maxBytes = 1 })
assert(Step.last_metadata.tripwire_count == 0 and tiny == "return 1")
local capped = Step.apply("return 1", { maxTripwires = 20, density = 1, maxBytes = 50 })
assert(Step.last_metadata.tripwire_count == 0 and capped == "return 1")
print("anti-deobfuscation: passed")
