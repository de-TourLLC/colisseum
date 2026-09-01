local Lexer = require("src.core.lexer")

local Step = { name = "decimal-padding", version = 1 }

local function adjacent_identifier(source, token)
    local before = source:sub(token.start - 1, token.start - 1)
    local after = source:sub(token.finish + 1, token.finish + 1)
    return before:match("[%a_]") ~= nil or after:match("[%a_]") ~= nil or
        before == "." or after == "."
end

local function padded(value)
    local mantissa, exponent = value:match("^([%d%.]+)([eE][%+%-]?%d+)$")
    if not mantissa then mantissa, exponent = value, "" end
    if not mantissa:find(".", 1, true) then
        mantissa = mantissa .. ".0"
    elseif mantissa:sub(-1) == "." then
        mantissa = mantissa .. "0"
    elseif mantissa:sub(1, 1) == "." then
        mantissa = "0" .. mantissa
    else
        mantissa = mantissa .. "0"
    end
    return mantissa .. exponent
end

function Step.apply(source)
    if type(source) ~= "string" then error("decimal-padding: source must be a string") end
    local output, cursor = {}, 1
    for _, token in ipairs(Lexer.scan(source)) do
        output[#output + 1] = source:sub(cursor, token.start - 1)
        local value = token.value
        -- The lexer intentionally has no hex token. Skip identifier-adjacent pieces.
        if token.kind == "number" and not adjacent_identifier(source, token) and
            value:match("^%d+%.?%d*[eE][%+%-]?%d+$") or
            token.kind == "number" and not adjacent_identifier(source, token) and value:match("^%d+%.?%d*$") or
            token.kind == "number" and not adjacent_identifier(source, token) and value:match("^%.[%d]+$") then
            value = padded(value)
        end
        output[#output + 1] = value
        cursor = token.finish + 1
    end
    output[#output + 1] = source:sub(cursor)
    return table.concat(output)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
