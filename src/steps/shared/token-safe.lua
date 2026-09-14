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

-- Top-level statement boundaries in `body`: the start, and each position after a
-- `;` or `end`. `until` is not a boundary but still counts toward depth.
local function statement_boundaries(body)
    local tokens = Lexer.scan(body)
    local points = { 1 }
    -- One nesting counter for both block keywords and brackets; a boundary only
    -- counts at depth 0.
    local depth = 0
    for index, token in ipairs(tokens) do
        local prev = tokens[index - 1]
        if prev and token.start > 1 and depth == 0 and (prev.value == ";" or prev.value == "end") then
            points[#points + 1] = token.start
        end
        local value = token.value
        if value == "then" or value == "do" or value == "function" or value == "repeat"
            or value == "(" or value == "{" or value == "[" then
            depth = depth + 1
        elseif value == "end" or value == "until" or value == ")" or value == "}" or value == "]" then
            if depth > 0 then depth = depth - 1 end
        end
    end
    return points
end

-- Splice blocks into body at random statement boundaries, not one contiguous prefix a deobfuscator could cut out.
function Safe.interleave(body, prng, blocks)
    if type(body) ~= "string" then error("token-safe: body must be a string") end
    if #blocks == 0 then return body end
    local points = statement_boundaries(body)
    -- Assign each block to a randomly chosen existing boundary (with replacement).
    -- Position 1 is always present, so there is always a safe home for every block.
    local at_point = {}
    for _, point in ipairs(points) do at_point[point] = {} end
    for _, text in ipairs(blocks) do
        local point = points[prng:range(1, #points)]
        local bucket = at_point[point]
        bucket[#bucket + 1] = text
    end
    table.sort(points)
    local parts, cursor = {}, 1
    for _, point in ipairs(points) do
        local bucket = at_point[point]
        if #bucket > 0 then
            parts[#parts + 1] = body:sub(cursor, point - 1)
            for _, text in ipairs(bucket) do parts[#parts + 1] = text end
            cursor = point
        end
    end
    parts[#parts + 1] = body:sub(cursor)
    return table.concat(parts)
end

return Safe
