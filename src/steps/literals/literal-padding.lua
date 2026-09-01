local Lexer = require("src.core.lexer")

local Step = {}
Step.name = "literal-padding"
Step.version = 1

function Step.apply(source)
    if type(source) ~= "string" then
        error("literal-padding: source must be a string")
    end

    local tokens = Lexer.scan(source)
    -- Single forward pass into a buffer: O(n) instead of rebuilding the whole
    -- source string on every wrapped literal.
    local out, cursor = {}, 1
    for index = 1, #tokens do
        local token = tokens[index]
        if token.kind == "number" or token.kind == "string" then
            out[#out + 1] = source:sub(cursor, token.start - 1)
            out[#out + 1] = "(" .. token.value .. ")"
            cursor = token.finish + 1
        end
    end
    out[#out + 1] = source:sub(cursor)
    return table.concat(out)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
