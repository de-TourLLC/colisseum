local Safe = require("src.steps.shared.token-safe")

local Step = { name = "deterministic-layout", version = 1, description = "Normalizes indentation to a deterministic width while retaining line boundaries." }

function Step.apply(source, options)
    options = options or {}
    local width = options.width or options.indent or 4
    if type(width) ~= "number" or width < 1 or width % 1 ~= 0 then error(Step.name .. ": width must be a positive integer") end
    local depth = 0
    return Safe.rewrite(source, function(value, previous, current)
        if not value:find("[\r\n]") then return value end
        local lines = value:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("^[ \t]+", ""):gsub("[ \t]+", "")
        if current and current.kind == "symbol" and (current.value == "end" or current.value == "}" or current.value == ")") then depth = math.max(0, depth - 1) end
        return lines:gsub("\n([ \t]*)", function() return "\n" .. string.rep(" ", depth * width) end)
    end, function(token)
        if token.kind == "symbol" and (token.value == "{" or token.value == "(" ) then depth = depth + 1 end
        return token.value
    end)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
