local Safe = require("src.steps.shared.token-safe")

local Step = { name = "tab-indent-normalize", version = 1, description = "Expands tabs in unprotected source gaps to a configured number of spaces." }

function Step.apply(source, options)
    options = options or {}
    local width = options.width or 4
    if type(width) ~= "number" or width < 1 or width % 1 ~= 0 then error(Step.name .. ": width must be a positive integer") end
    return Safe.rewrite(source, function(value) return value:gsub("\t", string.rep(" ", width)) end, function(token) return token.value end)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
