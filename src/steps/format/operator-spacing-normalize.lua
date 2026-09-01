local Safe = require("src.steps.shared.token-safe")

local operators = {
    ["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true, ["%"] = true,
    ["^"] = true, ["#"] = true, ["="] = true, ["=="] = true, ["~="] = true,
    ["<"] = true, [">"] = true, ["<="] = true, [">="] = true, [".."] = true,
    ["&"] = true, ["|"] = true, ["~"] = true, ["<<"] = true, [">>"] = true
}

local Step = {
    name = "operator-spacing-normalize",
    version = 1,
    description = "Adds consistent same-line spacing around recognized operators.",
    dependencies = {}
}

function Step.apply(source)
    return Safe.rewrite(source, function(value, previous, current, index)
        if not Safe.same_line(value) or not previous or not current or previous.protected or current.protected then
            return value
        end
        if operators[previous.value] or operators[current.value] then return " " end
        return value
    end, function(token)
        return token.value
    end)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
