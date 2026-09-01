local Lexer = require("src.core.lexer")

local Step = { name = "literal-grouping", version = 1 }

function Step.apply(source)
    if type(source) ~= "string" then error("literal-grouping: source must be a string") end
    local output, cursor = {}, 1
    for _, token in ipairs(Lexer.scan(source)) do
        output[#output + 1] = source:sub(cursor, token.start - 1)
        if (token.kind == "number" or (token.kind == "string" and token.value:sub(1, 1) ~= "[")) or
            (token.kind == "identifier" and (token.value == "true" or token.value == "false" or token.value == "nil")) then
            output[#output + 1] = "(" .. token.value .. ")"
        else
            output[#output + 1] = token.value
        end
        cursor = token.finish + 1
    end
    output[#output + 1] = source:sub(cursor)
    return table.concat(output)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
