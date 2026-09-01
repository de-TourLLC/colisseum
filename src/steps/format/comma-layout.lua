local Safe = require("src.steps.shared.token-safe")

local Step = { name = "comma-layout", version = 1, description = "Uses one space after same-line commas and no space before them." }

function Step.apply(source)
    return Safe.rewrite(source, function(value, previous, current)
        if not Safe.same_line(value) or not previous or not current then return value end
        if current.value == "," then return "" end
        if previous.value == "," then return " " end
        return value
    end, function(token) return token.value end)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
