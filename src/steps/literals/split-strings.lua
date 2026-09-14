local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")
local Entropy = require("src.core.entropy")

local Step = {}
Step.name = "split-strings"
Step.version = 1

-- Split each plain quoted string literal into concatenated pieces so it never appears verbatim.

-- Scan for escape-free quoted literals safe to split, recording the quote char.
-- Mirrors constant-array's collect_strings.
local function collect_strings(body)
    local occurrences = {}
    local index, length = 1, #body
    while index <= length do
        local char = body:sub(index, index)
        if char == "-" and body:sub(index, index + 1) == "--" then
            -- Line or long-form comment: skip its whole span.
            local long = body:sub(index + 2, index + 3) == "[["
            local finish = long and (body:find("]]", index + 4, true) or length) or
                (body:find("\n", index + 2, true) or length + 1)
            index = finish + (long and 2 or 1)
        elseif char == "[" and body:sub(index, index + 1) == "[[" then
            -- Long string: skip, we never split these.
            local finish = body:find("]]", index + 2, true) or length - 1
            index = finish + 2
        elseif char == "\"" or char == "'" then
            -- Quoted literal: walk to the matching unescaped quote.
            local quote, finish, escaped = char, index + 1, false
            while finish <= length do
                local current = body:sub(finish, finish)
                if current == quote and not escaped then break end
                escaped = current == "\\" and not escaped
                if current ~= "\\" then escaped = false end
                finish = finish + 1
            end
            local value = body:sub(index + 1, finish - 1)
            -- Only terminated, escape-free literals can be re-quoted verbatim.
            if finish <= length and not value:find("\\", 1, true) then
                occurrences[#occurrences + 1] =
                    { start = index, finish = finish, value = value, quote = quote }
            end
            index = finish + 1
        else
            index = index + 1
        end
    end
    return occurrences
end

-- Split `value` into `pieces` non-empty chunks at prng-chosen boundaries, returning the parenthesised concatenation.
local function split_literal(value, quote, pieces, prng)
    -- Choose `pieces - 1` distinct cut positions so every piece is non-empty.
    local want = pieces - 1
    local cuts, seen = {}, {}
    while #cuts < want do
        local position = prng:range(1, #value - 1)
        if not seen[position] then
            seen[position] = true
            cuts[#cuts + 1] = position
        end
    end
    table.sort(cuts)

    -- Re-quote each chunk with the original quote char; the value is escape-free so this is safe.
    local out, previous = {}, 0
    for _, position in ipairs(cuts) do
        out[#out + 1] = quote .. value:sub(previous + 1, position) .. quote
        previous = position
    end
    out[#out + 1] = quote .. value:sub(previous + 1) .. quote
    return "(" .. table.concat(out, "..") .. ")"
end

function Step.apply(source, options)
    if type(source) ~= "string" then error("split-strings: source must be a string") end
    if options ~= nil and type(options) ~= "table" then error("split-strings: options must be a table") end
    options = options or {}
    local prng = Entropy.prng(options.seed or "split-strings")

    -- Preserve a leading shebang; it is not Lua and must stay on line 1.
    local shebang = source:match("^(#![^\n]*\n)") or ""
    local body = source:sub(#shebang + 1)

    local occurrences = collect_strings(body)

    -- Rebuild the body, splitting every literal of length >= 2; shorter ones are left as-is.
    local out, cursor, splits = {}, 1, 0
    for _, occ in ipairs(occurrences) do
        if #occ.value >= 2 then
            out[#out + 1] = body:sub(cursor, occ.start - 1)
            -- 2..4 pieces, but never more than the value length (each piece >= 1 byte).
            local pieces = math.min(prng:range(2, 4), #occ.value)
            out[#out + 1] = split_literal(occ.value, occ.quote, pieces, prng)
            cursor = occ.finish + 1
            splits = splits + 1
        end
    end

    -- Nothing eligible: return the input untouched.
    if splits == 0 then return source end

    out[#out + 1] = body:sub(cursor)
    local result = shebang .. table.concat(out)

    local valid, message, position = Validate.syntax(result)
    if not valid then
        error("split-strings: generated source is invalid at " .. tostring(position) .. ": " .. tostring(message))
    end
    Step.last_metadata = { split = splits, occurrences = #occurrences, validated = true }
    return result
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
