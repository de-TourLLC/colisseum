local Lexer = require("src.core.lexer")

local Step = {}
Step.name = "line-ending-normalize"
Step.version = 1

local function normalize_gap(value)
    return value:gsub("\r\n", "\n"):gsub("\r", "\n")
end

function Step.apply(source)
    if type(source) ~= "string" then
        error("line-ending-normalize: source must be a string")
    end

    local output = {}
    local cursor = 1
    for _, token in ipairs(Lexer.scan(source)) do
        output[#output + 1] = normalize_gap(source:sub(cursor, token.start - 1))
        output[#output + 1] = token.value
        cursor = token.finish + 1
    end
    output[#output + 1] = normalize_gap(source:sub(cursor))
    return table.concat(output)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
