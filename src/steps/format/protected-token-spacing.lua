local Lexer = require("src.core.lexer")

local Step = { name = "protected-token-spacing", version = 1 }

local function needs_space(left, right)
    if not left or not right or left.kind == "comment" or right.kind == "comment" then return false end
    local joined = Lexer.scan(left.value .. right.value)
    return #joined ~= 2 or joined[1].value ~= left.value or joined[2].value ~= right.value
end

function Step.apply(source)
    if type(source) ~= "string" then error(Step.name .. ": source must be a string") end
    local tokens, output, cursor, previous = Lexer.scan(source), {}, 1, nil
    for _, token in ipairs(tokens) do
        local gap = source:sub(cursor, token.start - 1)
        if gap == "" and needs_space(previous, token) then gap = " " end
        output[#output + 1] = gap
        output[#output + 1] = token.value
        previous, cursor = token, token.finish + 1
    end
    output[#output + 1] = source:sub(cursor)
    return table.concat(output)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
