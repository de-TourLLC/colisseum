local Safe = require("src.steps.shared.token-safe")

local Step = { name = "final-newline-policy", version = 1, description = "Ensures source ends with exactly one configured unprotected newline." }

function Step.apply(source, options)
    options = options or {}
    local ending = options.style == "crlf" and "\r\n" or "\n"
    local output = Safe.rewrite(source, function(value, previous, current)
        if current == nil then
            value = value:gsub("[ \t\r\n]*$", "")
            return value .. ending
        end
        return value
    end, function(token) return token.value end)
    return output
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
