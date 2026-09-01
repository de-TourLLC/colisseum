local Lexer = require("src.core.lexer")

local Step = {}
Step.name = "blank-line-collapse"
Step.version = 1

local function collapse(value)
    -- Keep the existing newline style; only remove surplus empty lines.
    local changed
    repeat
        local count = 0
        value, changed = value:gsub("([ \t]*\r\n)[ \t]*\r\n", "%1")
        count = count + changed
        value, changed = value:gsub("([ \t]*\n)[ \t]*\n", "%1")
        count = count + changed
        value, changed = value:gsub("([ \t]*\r)[ \t]*\r", "%1")
        count = count + changed
        changed = count
    until changed == 0
    return value
end

function Step.apply(source)
    if type(source) ~= "string" then
        error("blank-line-collapse: source must be a string")
    end

    local output = {}
    local cursor = 1
    for _, token in ipairs(Lexer.scan(source)) do
        output[#output + 1] = collapse(source:sub(cursor, token.start - 1))
        output[#output + 1] = token.value
        cursor = token.finish + 1
    end
    output[#output + 1] = collapse(source:sub(cursor))
    return table.concat(output)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
