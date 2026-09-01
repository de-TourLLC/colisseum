local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")

local Step = { name = "operator-usage-report", version = 1 }
Step.metadata = { id = Step.name, version = Step.version, kind = "analysis", description = "Reports the operators present in validated source." }

function Step.apply(source)
    if type(source) ~= "string" then error(Step.name .. ": source must be a string") end
    local valid, message, position = Validate.syntax(source)
    if not valid then error(Step.name .. ": " .. message .. " at " .. position) end
    local counts, total = {}, 0
    for _, token in ipairs(Lexer.scan(source)) do if token.kind == "symbol" then counts[token.value] = (counts[token.value] or 0) + 1; total = total + 1 end end
    Step.last_metadata = { operator_count = total, operator_counts = counts, validated = true }
    return source
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
