local Lexer = require("src.core.lexer")

local Step = { name = "semicolon-policy", version = 1 }

function Step.apply(source, options)
    if type(source) ~= "string" then error(Step.name .. ": source must be a string") end
    options = options or {}
    local policy = options.policy or options.style or "newline"
    if policy ~= "newline" and policy ~= "preserve" then
        error(Step.name .. ": policy must be 'newline' or 'preserve'")
    end

    local output, cursor = {}, 1
    for _, token in ipairs(Lexer.scan(source)) do
        output[#output + 1] = source:sub(cursor, token.start - 1)
        if token.kind == "symbol" and token.value == ";" and policy == "newline" then
            output[#output + 1] = "\n"
        else
            output[#output + 1] = token.value
        end
        cursor = token.finish + 1
    end
    output[#output + 1] = source:sub(cursor)
    return table.concat(output)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
