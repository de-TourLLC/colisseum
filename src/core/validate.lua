local Lexer = require("src.core.lexer")

local Validate = {}

function Validate.syntax(source)
    local stack = {}
    local pairs = { [")"] = "(", ["]"] = "[", ["}"] = "{" }
    for _, token in ipairs(Lexer.scan(source)) do
        if token.kind == "symbol" then
            if token.value == "(" or token.value == "[" or token.value == "{" then
                stack[#stack + 1] = token
            elseif pairs[token.value] then
                local opening = stack[#stack]
                if not opening or opening.value ~= pairs[token.value] then
                    return false, "unexpected " .. token.value, token.start
                end
                stack[#stack] = nil
            end
        end
    end
    if #stack > 0 then
        return false, "unclosed " .. stack[#stack].value, stack[#stack].start
    end
    return true
end

return Validate
