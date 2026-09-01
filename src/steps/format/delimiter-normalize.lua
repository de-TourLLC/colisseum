local Safe = require("src.steps.shared.token-safe")

local opening = { ["("] = true, ["["] = true, ["{"] = true }
local closing = { [")"] = true, ["]"] = true, ["}"] = true }

local Step = {
    name = "delimiter-normalize",
    version = 1,
    description = "Normalizes safe same-line whitespace adjacent to delimiters and separators.",
    dependencies = {}
}

function Step.apply(source)
    return Safe.rewrite(source, function(value, previous, current)
        if not Safe.same_line(value) or not previous or not current or previous.protected or current.protected then
            return value
        end
        if opening[previous.value] or closing[current.value] then return "" end
        if current.value == "," or current.value == ";" then return "" end
        if previous.value == "," or previous.value == ";" then
            return closing[current.value] and "" or " "
        end
        return value
    end, function(token)
        return token.value
    end)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
