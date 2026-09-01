-- Measures CLBC compilation and decoding. No decoded data is executed here.

local Common = require("benchmarks.common")
local Obfuscator = require("src.obfuscator")
local Bytecode = require("src.core.bytecode")

local encoded = Obfuscator.compile(Common.source)

local function run()
    Common.header("Bytecode benchmarks")
    print(string.format("fixed encoded size: %d bytes", #encoded))
    Common.measure("bytecode compile", 100, function()
        return Obfuscator.compile(Common.source)
    end)
    Common.measure("bytecode decode", 100, function()
        return Bytecode.decode(encoded)
    end)
end

return run
