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

-- Collect every safe top-level (depth 0) statement boundary in `body`: the very
-- start plus each position right after a `;` or `end`. Splicing a whole statement
-- in at one of these can never corrupt the program.
--
-- Note: `until` is deliberately NOT treated as a boundary marker. Unlike `;`/`end`,
-- a statement does not end at `until` -- the keyword is followed by the repeat
-- loop's condition EXPRESSION, so inserting a statement right after `until` yields
-- `until <stmt> <condition>`, which is invalid. `until` still drives depth (below)
-- so boundaries inside a repeat body are correctly suppressed.
local function statement_boundaries(body)
    local tokens = Lexer.scan(body)
    local points = { 1 }
    -- One combined nesting counter: block keywords AND brackets both raise it, so
    -- a position is only a real top-level statement boundary when the counter is 0
    -- (outside every block, table constructor, call-arg list, and index). Without
    -- the bracket half, an `end` closing a `function` INSIDE a `{...}` table or a
    -- `(...)` call would look like a boundary and splicing there would corrupt the
    -- literal (e.g. `{ __index = function() ... end <stmt> }`).
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

-- Splice `blocks` (a list of ready-to-insert source strings, each already framed
-- with its own leading/trailing newline) into `body` at random top-level
-- statement boundaries, rather than concatenating them into one contiguous prefix
-- a deobfuscator could strip in a single cut. Returns the interleaved source.
--
-- Every boundary returned by statement_boundaries is a proven-safe insertion site
-- (position 1, or immediately before the token that follows a `;`/`end`/`until`),
-- so inserting any number of statements there cannot corrupt the program. Blocks
-- are ONLY ever placed at these boundaries -- never appended past the end of the
-- body, which could land a statement after a trailing top-level `return` (illegal
-- Lua). More blocks than boundaries simply means some boundaries take several.
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
