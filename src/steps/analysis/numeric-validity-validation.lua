local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")

local Step = { name = "numeric-validity-validation", version = 1 }
Step.metadata = { id = Step.name, version = Step.version, kind = "validation", description = "Checks that every lexed numeric literal is a complete decimal literal." }

function Step.apply(source)
    if type(source) ~= "string" then error(Step.name .. ": source must be a string") end
    local valid, message, position = Validate.syntax(source)
    if not valid then error(Step.name .. ": " .. message .. " at " .. position) end
    local tokens, numbers = Lexer.scan(source), 0
    for index, token in ipairs(tokens) do
        if token.kind == "number" then
            numbers = numbers + 1
            if not token.value:match("^%d+%.?%d*[eE][%+%-]?%d+$") and not token.value:match("^%d+%.?%d*$") and not token.value:match("^%.[%d]+$") then error(Step.name .. ": invalid number at " .. token.start) end
            local next_token = tokens[index + 1]
            if next_token and next_token.start == token.finish + 1 and (next_token.kind == "identifier" or next_token.kind == "number") then error(Step.name .. ": adjacent numeric text at " .. token.start) end
        end
    end
    Step.last_metadata = { numeric_literal_count = numbers, validated = true }
    return source
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
