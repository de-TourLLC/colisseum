local Safe = require("src.steps.shared.token-safe")

local Step = {
    name = "numeric-base-normalize",
    version = 1,
    description = "Removes redundant leading zeroes from safe decimal integer literals.",
    dependencies = {}
}

function Step.apply(source)
    return Safe.rewrite(source, function(value)
        return value
    end, function(token)
        if token.kind ~= "number" or not token.value:match("^%d+$") then return token.value end
        local normalized = token.value:gsub("^0+", "")
        return normalized == "" and "0" or normalized
    end)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
