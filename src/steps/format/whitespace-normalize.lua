local Lexer = require("src.core.lexer")

local Step = {}
Step.name = "whitespace-normalize"
Step.version = 1

local function normalize(value)
    if value == "" then return value end
    -- A newline is required after a line comment; preserving one also keeps
    -- statement locations broadly useful without changing protected tokens.
    if value:find("[\r\n]") then return "\n" end
    return " "
end

function Step.apply(source)
    if type(source) ~= "string" then
        error("whitespace-normalize: source must be a string")
    end

    local output = {}
    local cursor = 1
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
