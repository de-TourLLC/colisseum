local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")

local Safe = {}

local function valid_tokens(source)
    local ok, tokens, valid, message, position = pcall(function()
        local tokens = Lexer.scan(source)
        local syntax_ok, syntax_message, syntax_position = Validate.syntax(source)
        return tokens, syntax_ok, syntax_message, syntax_position
    end)
    if not ok then error("token-safe: unable to validate source: " .. tostring(tokens)) end
    if not valid then
        error("token-safe: invalid source at " .. tostring(position) .. ": " .. tostring(message))
    end
    return tokens
end

function Safe.scan(source)
    if type(source) ~= "string" then error("token-safe: source must be a string") end
    local tokens = Lexer.scan(source)
    valid_tokens(source)
    return tokens
end

function Safe.gap(value)
    if value == "" then return value end
    value = value:gsub("\r\n", "\n"):gsub("\r", "\n")
    if value:find("\n", 1, true) then return "\n" end
    return " "
end

function Safe.rewrite(source, transform_gap, transform_token)
    local tokens = Safe.scan(source)
    local output, cursor = {}, 1
    for index, token in ipairs(tokens) do
        local before = source:sub(cursor, token.start - 1)
        output[#output + 1] = transform_gap(before, tokens[index - 1], token, index)
        output[#output + 1] = token.protected and token.value or transform_token(token, index, tokens)
        cursor = token.finish + 1
    end
    output[#output + 1] = transform_gap(source:sub(cursor), tokens[#tokens], nil, #tokens + 1)
    local result = table.concat(output)
    valid_tokens(result)
    return result
end

function Safe.same_line(value)
    return not value:find("[\r\n]")
end

return Safe
