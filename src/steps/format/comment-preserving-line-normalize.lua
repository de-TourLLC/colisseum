local Lexer = require("src.core.lexer")

local Step = { name = "comment-preserving-line-normalize", version = 1 }

local function normalize(value)
    return value:gsub("\r\n", "\n"):gsub("\r", "\n")
end

function Step.apply(source)
    if type(source) ~= "string" then
        error(Step.name .. ": source must be a string")
    end

    local output, cursor = {}, 1
    for _, token in ipairs(Lexer.scan(source)) do
        output[#output + 1] = normalize(source:sub(cursor, token.start - 1))
        output[#output + 1] = token.value
        cursor = token.finish + 1
    end
    output[#output + 1] = normalize(source:sub(cursor))
    return table.concat(output)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
