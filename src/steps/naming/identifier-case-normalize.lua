local Safe = require("src.steps.shared.token-safe")

local Step = {
    name = "identifier-case-normalize",
    version = 1,
    description = "Normalizes source whitespace and token boundaries without changing identifiers.",
    dependencies = {}
}

function Step.apply(source)
    return Safe.rewrite(source, function(value)
        return Safe.gap(value)
    end, function(token)
        return token.value
    end)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
