local Safe = require("src.steps.shared.token-safe")

local Step = { name = "comment-policy", version = 1, description = "Removes trailing horizontal whitespace immediately before protected comments." }

function Step.apply(source)
    return Safe.rewrite(source, function(value, previous, current)
        if current and current.kind == "comment" and not value:find("[\r\n]") then
            return value:gsub("[ \t]+$", "")
        end
        return value
    end, function(token) return token.value end)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
