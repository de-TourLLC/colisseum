local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")

local Step = { name = "function-budget-analysis", version = 1 }
Step.metadata = { id = Step.name, version = Step.version, kind = "validation", description = "Counts function declarations against a configurable source budget." }

function Step.apply(source, options)
    if type(source) ~= "string" then error(Step.name .. ": source must be a string") end
    if options ~= nil and type(options) ~= "table" then error(Step.name .. ": options must be a table") end
    local valid, message, position = Validate.syntax(source)
    if not valid then error(Step.name .. ": " .. message .. " at " .. position) end
    local limit = (options or {}).max_functions or 100
    if type(limit) ~= "number" or limit < 1 or limit % 1 ~= 0 then error(Step.name .. ": max_functions must be a positive integer") end
    local count = 0
    for _, token in ipairs(Lexer.scan(source)) do if token.kind == "identifier" and token.value == "function" then count = count + 1 end end
    if count > limit then error(Step.name .. ": function budget exceeded (" .. count .. "/" .. limit .. ")") end
    Step.last_metadata = { function_count = count, function_limit = limit, validated = true }
    return source
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
