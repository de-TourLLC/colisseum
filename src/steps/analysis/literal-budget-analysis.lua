local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")

local Step = { name = "literal-budget-analysis", version = 1 }
Step.metadata = { id = Step.name, version = Step.version, kind = "validation", description = "Counts literal tokens against a configurable budget." }

function Step.apply(source, options)
    if type(source) ~= "string" then error(Step.name .. ": source must be a string") end
    if options ~= nil and type(options) ~= "table" then error(Step.name .. ": options must be a table") end
    local valid, message, position = Validate.syntax(source)
    if not valid then error(Step.name .. ": " .. message .. " at " .. position) end
    local limit = (options or {}).max_literals or 10000
    if type(limit) ~= "number" or limit < 1 or limit % 1 ~= 0 then error(Step.name .. ": max_literals must be a positive integer") end
    local count = 0
    for _, token in ipairs(Lexer.scan(source)) do if token.kind == "string" or token.kind == "number" or (token.kind == "identifier" and (token.value == "true" or token.value == "false" or token.value == "nil")) then count = count + 1 end end
    if count > limit then error(Step.name .. ": literal budget exceeded (" .. count .. "/" .. limit .. ")") end
    Step.last_metadata = { literal_count = count, literal_limit = limit, validated = true }
    return source
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
