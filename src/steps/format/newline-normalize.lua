local Safe = require("src.steps.shared.token-safe")

local Step = {
    name = "newline-normalize",
    version = 1,
    description = "Converts unprotected CRLF and CR line endings to LF.",
    dependencies = {}
}

function Step.apply(source)
    return Safe.rewrite(source, function(value)
        return value:gsub("\r\n", "\n"):gsub("\r", "\n")
    end, function(token)
        return token.value
    end)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
