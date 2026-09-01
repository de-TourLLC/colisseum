local Lexer = require("src.core.lexer")

local Step = {}
Step.name = "quote-normalize"
Step.version = 1

local function normalize(value)
    local quote = value:sub(1, 1)
    if value:sub(-1) ~= quote then return value end
    local other = quote == '"' and "'" or '"'
    local body = value:sub(2, -2)
    if body:find("\\", 1, true) or body:find(other, 1, true) or body:find("[\r\n]") then
        return value
    end
    return other .. body .. other
end

function Step.apply(source)
    if type(source) ~= "string" then
        error("quote-normalize: source must be a string")
    end

    local output = {}
    local cursor = 1
    for _, token in ipairs(Lexer.scan(source)) do
        output[#output + 1] = source:sub(cursor, token.start - 1)
        if token.kind == "string" and token.value:sub(1, 1) ~= "[" then
            output[#output + 1] = normalize(token.value)
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
