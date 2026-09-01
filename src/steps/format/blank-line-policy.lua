local Lexer = require("src.core.lexer")

local Step = { name = "blank-line-policy", version = 1 }

local function limit(value, maximum)
    local newlines = 0
    local result = value:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", function()
        newlines = newlines + 1
        return newlines > maximum + 1 and "" or "\n"
    end)
    return result
end

function Step.apply(source, options)
    if type(source) ~= "string" then error(Step.name .. ": source must be a string") end
    options = options or {}
    local maximum = options.max_blank_lines
    if maximum == nil then maximum = 1 end
    if type(maximum) ~= "number" or maximum < 0 or maximum % 1 ~= 0 then
        error(Step.name .. ": max_blank_lines must be a non-negative integer")
    end

    local output, cursor = {}, 1
    for _, token in ipairs(Lexer.scan(source)) do
        output[#output + 1] = limit(source:sub(cursor, token.start - 1), maximum)
        output[#output + 1] = token.value
        cursor = token.finish + 1
    end
    output[#output + 1] = limit(source:sub(cursor), maximum)
    return table.concat(output)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
