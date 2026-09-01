local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")

local Step = { name = "string-termination-validation", version = 1 }
Step.metadata = { id = Step.name, version = Step.version, kind = "validation", description = "Rejects unterminated quoted and long string literals." }

function Step.apply(source)
    if type(source) ~= "string" then error(Step.name .. ": source must be a string") end
    local valid, message, position = Validate.syntax(source)
    if not valid then error(Step.name .. ": " .. message .. " at " .. position) end
    local strings = 0
    for _, token in ipairs(Lexer.scan(source)) do
        if token.kind == "string" then
            strings = strings + 1
            local first, last = token.value:sub(1, 1), token.value:sub(-1)
            if (first == "'" or first == '"') and last ~= first then error(Step.name .. ": unterminated string at " .. token.start) end
            if first == "[" and not token.value:match("%]" .. token.value:match("^%[(=*)%[") .. "%]$") then error(Step.name .. ": unterminated long string at " .. token.start) end
        end
    end
    Step.last_metadata = { string_count = strings, validated = true }
    return source
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
