local Safe = require("src.steps.shared.token-safe")

local Step = { name = "line-ending-policy", version = 1, description = "Applies an explicit LF or CRLF policy to unprotected gaps." }

function Step.apply(source, options)
    options = options or {}
    local style = options.style or options.line_ending or "lf"
    if style ~= "lf" and style ~= "crlf" then error(Step.name .. ": style must be 'lf' or 'crlf'") end
    return Safe.rewrite(source, function(value)
        value = value:gsub("\r\n", "\n"):gsub("\r", "\n")
        return style == "crlf" and value:gsub("\n", "\r\n") or value
    end, function(token) return token.value end)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
