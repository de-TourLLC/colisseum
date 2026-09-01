-- Measures every built-in preset using one fixed, bounded source fixture.

local Common = require("benchmarks.common")
local Obfuscator = require("src.obfuscator")

local function run()
    Common.header("Preset transformation benchmarks")
    for _, name in ipairs({ "easy", "medium", "hard", "full", "secure", "total" }) do
        Common.measure("preset " .. name, 20, function()
            return Obfuscator.obfuscate(Common.source, { preset = name, target = "lua" })
        end)
    end
end

return run
