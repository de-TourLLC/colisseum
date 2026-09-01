local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")

local Step = { name = "dynamic-feature-guard", version = 1 }
Step.metadata = { id = Step.name, version = Step.version, kind = "validation", description = "Rejects dynamic code-loading and environment execution primitives." }
local forbidden = { load = true, loadstring = true, dostring = true, dofile = true, require = true }

function Step.apply(source, options)
    if type(source) ~= "string" then error(Step.name .. ": source must be a string") end
    local valid, message, position = Validate.syntax(source)
    if not valid then error(Step.name .. ": " .. message .. " at " .. position) end
    local count = 0
    for _, token in ipairs(Lexer.scan(source)) do if token.kind == "identifier" and forbidden[token.value] then count = count + 1; error(Step.name .. ": dynamic feature '" .. token.value .. "' at " .. token.start) end end
    Step.last_metadata = { dynamic_feature_count = count, validated = true }
    return source
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
