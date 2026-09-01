local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")

local Step = { name = "delimiter-validation", version = 1 }
Step.metadata = { id = Step.name, version = Step.version, kind = "validation", description = "Validates delimiter pairing and reports lexical depth." }

function Step.apply(source)
    if type(source) ~= "string" then error(Step.name .. ": source must be a string") end
    local valid, message, position = Validate.syntax(source)
    if not valid then error(Step.name .. ": " .. message .. " at " .. position) end
    local depth, maximum, pairs = 0, 0, 0
    for _, token in ipairs(Lexer.scan(source)) do
        if token.value == "(" or token.value == "[" or token.value == "{" then depth = depth + 1; pairs = pairs + 1; if depth > maximum then maximum = depth end
        elseif token.value == ")" or token.value == "]" or token.value == "}" then depth = depth - 1 end
    end
    Step.last_metadata = { delimiter_pairs = pairs, maximum_depth = maximum, validated = true }
    return source
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
