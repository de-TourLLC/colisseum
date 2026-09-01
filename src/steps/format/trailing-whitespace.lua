local Lexer = require("src.core.lexer")

local Step = {}
Step.name = "trailing-whitespace"
Step.version = 1

local function remove_trailing(value, at_end)
    value = value:gsub("[ \t]+\r\n", "\r\n")
    value = value:gsub("[ \t]+\n", "\n")
    value = value:gsub("[ \t]+\r", "\r")
    if at_end then value = value:gsub("[ \t]+$", "") end
    return value
end

function Step.apply(source)
    if type(source) ~= "string" then
        error("trailing-whitespace: source must be a string")
    end

    local output = {}
    local cursor = 1
    for _, token in ipairs(Lexer.scan(source)) do
        output[#output + 1] = remove_trailing(source:sub(cursor, token.start - 1), false)
        output[#output + 1] = token.value
        cursor = token.finish + 1
    end
    output[#output + 1] = remove_trailing(source:sub(cursor), true)
    return table.concat(output)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
