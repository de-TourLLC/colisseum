local Safe = require("src.steps.shared.token-safe")

local Step = { name = "delimiter-line-policy", version = 1, description = "Removes horizontal padding next to delimiters while preserving multiline layout." }
local opening = { ["("] = true, ["["] = true, ["{"] = true }
local closing = { [")"] = true, ["]"] = true, ["}"] = true }

function Step.apply(source)
    return Safe.rewrite(source, function(value, previous, current)
        if not Safe.same_line(value) or not previous or not current then return value end
        if (opening[previous.value] or closing[current.value]) and not previous.protected and not current.protected then return "" end
        return value
    end, function(token) return token.value end)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
