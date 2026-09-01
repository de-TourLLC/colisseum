local Safe = require("src.steps.shared.token-safe")

local Step = { name = "numeric-canonicalization", version = 1, description = "Canonicalizes decimal mantissas and exponent spelling without changing numeric values." }

local function canonical(value)
    local mantissa, exponent = value:match("^([%d%.]+)([eE][%+%-]?%d+)$")
    if not mantissa then mantissa, exponent = value, "" end
    if not mantissa:find(".", 1, true) then return value end
    local whole, fraction = mantissa:match("^(%d*)%.(%d*)$")
    if not whole then return value end
    whole = whole:gsub("^0+(%d)", "%1")
    fraction = fraction:gsub("0+$", "")
    if whole == "" then whole = "0" end
    mantissa = fraction == "" and whole or whole .. "." .. fraction
    local sign, digits = exponent:match("^([eE][%+%-]?)(%d+)$")
    if sign then
        digits = digits:gsub("^0+", "")
        exponent = sign:sub(1, 1):lower() .. (sign:sub(2) == "+" and "" or sign:sub(2)) .. (digits == "" and "0" or digits)
    end
    return mantissa .. exponent
end

function Step.apply(source)
    return Safe.rewrite(source, function(value) return value end, function(token)
        return token.kind == "number" and canonical(token.value) or token.value
    end)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
