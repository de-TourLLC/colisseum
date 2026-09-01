local Lexer = require("src.core.lexer")

local Step = { name = "nil-normalize", version = 1 }

function Step.apply(source)
    if type(source) ~= "string" then error("nil-normalize: source must be a string") end
    local output, cursor = {}, 1
    for _, token in ipairs(Lexer.scan(source)) do
        output[#output + 1] = source:sub(cursor, token.start - 1)
        output[#output + 1] = token.kind == "identifier" and token.value == "nil" and "(nil)" or token.value
        cursor = token.finish + 1
    end
    output[#output + 1] = source:sub(cursor)
    return table.concat(output)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
