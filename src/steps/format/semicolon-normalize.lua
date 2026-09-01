local Lexer = require("src.core.lexer")

local Step = {}
Step.name = "semicolon-normalize"
Step.version = 1

function Step.apply(source)
    if type(source) ~= "string" then
        error("semicolon-normalize: source must be a string")
    end

    local output = {}
    local cursor = 1
    for _, token in ipairs(Lexer.scan(source)) do
        output[#output + 1] = source:sub(cursor, token.start - 1)
        output[#output + 1] = token.kind == "symbol" and token.value == ";" and "\n" or token.value
        cursor = token.finish + 1
    end
    output[#output + 1] = source:sub(cursor)
    return table.concat(output)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
