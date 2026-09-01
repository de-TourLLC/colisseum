local Safe = require("src.steps.shared.token-safe")

local Step = { name = "protected-literal-formatting", version = 1, description = "Gives protected string literals deterministic surrounding spacing without changing their contents." }

function Step.apply(source)
    return Safe.rewrite(source, function(value, previous, current)
        if not Safe.same_line(value) or not previous or not current then return value end
        if current.kind == "string" and current.protected and previous.kind ~= "symbol" then return " " end
        if previous.kind == "string" and previous.protected and current.kind ~= "symbol" then return " " end
        return value
    end, function(token) return token.value end)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
