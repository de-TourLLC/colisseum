local Safe = require("src.steps.shared.token-safe")

local operators = { ["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true, ["%"] = true, ["^"] = true, ["="] = true, ["=="] = true, ["~="] = true, ["<"] = true, [">"] = true, ["<="] = true, [">="] = true, [".."] = true, ["//"] = true }
local Step = { name = "operator-canonicalization", version = 1, description = "Uses one space around binary operators while retaining unary and protected syntax." }

function Step.apply(source)
    return Safe.rewrite(source, function(value, previous, current)
        if not Safe.same_line(value) or not previous or not current or previous.protected or current.protected then return value end
        if operators[previous.value] or operators[current.value] then
            if current.value == "-" and (not previous or operators[previous.value] or previous.value == "(") then return " " end
            return " "
        end
        return value
    end, function(token) return token.value end)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
