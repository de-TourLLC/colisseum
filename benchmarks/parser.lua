-- Measures parsing of one fixed, bounded source fixture.

local Common = require("benchmarks.common")
local Parser = require("src.core.parser")

local function run()
    Common.header("Parser benchmarks")
    Common.measure("parser.parse", 100, function()
        return Parser.parse(Common.source)
    end)
end

return run
