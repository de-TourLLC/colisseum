-- Measures the restricted CLBC runtime on one fixed, bounded program.
-- This intentionally does not call load, loadstring, or execute source text.

local Common = require("benchmarks.common")
local Obfuscator = require("src.obfuscator")
local Bytecode = require("src.core.bytecode")
local Runtime = require("src.core.runtime")

local program = Bytecode.decode(Obfuscator.compile(Common.source))
local check = Runtime.run(program, {
    steps = 1000,
    depth = 64,
    loop_iterations = 32
})
assert(check[1] == 905, "fixed runtime fixture returned an unexpected value")

local function run()
    Common.header("Restricted runtime benchmarks")
    print(string.format("fixed program instructions: %d", #program.instructions))
    Common.measure("runtime.run", 100, function()
        local values, stats = Runtime.run(program, {
            steps = 1000,
            depth = 64,
            loop_iterations = 32
        })
        return values[1], stats
    end)
end

return run
