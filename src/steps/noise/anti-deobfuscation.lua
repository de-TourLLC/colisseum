local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")
local Entropy = require("src.core.entropy")

local Step = {
    name = "anti-deobfuscation",
    version = 2
}

Step.metadata = {
    id = Step.name,
    version = Step.version,
    kind = "transformation",
    description = "Adds bounded dead static tripwires at safe top-level source boundaries."
}

local function positive_option(options, name, default)
    local value = tonumber(options[name])
    if value == nil or value < 1 then return default end
    return math.floor(value)
end

local function validate(source, label)
    local ok, message, position = Validate.syntax(source)
    if not ok then
        error(Step.name .. ": " .. label .. " is invalid at " .. tostring(position) .. ": " .. tostring(message))
    end
end

local function top_level_boundaries(source, tokens, first_offset)
    local boundaries = { first_offset }
    local block_depth, delimiter_depth = 0, 0
    local previous

    for index, token in ipairs(tokens) do
        local value = token.value
        local gap = source:sub((previous and previous.finish + 1 or first_offset), token.start - 1)
        local safe_after_block = previous and (previous.value == "end" or previous.value == ";")
        if block_depth == 0 and delimiter_depth == 0 and gap:find("[\r\n]") and safe_after_block then
            boundaries[#boundaries + 1] = token.start
        end

        if token.kind == "symbol" then
            if value == "(" or value == "[" or value == "{" then
                delimiter_depth = delimiter_depth + 1
            elseif value == ")" or value == "]" or value == "}" then
                delimiter_depth = math.max(0, delimiter_depth - 1)
            end
        elseif token.kind == "identifier" then
            if value == "function" or value == "if" or value == "repeat" or value == "do" then
                block_depth = block_depth + 1
            elseif value == "end" or value == "until" then
                block_depth = math.max(0, block_depth - 1)
            end
        end
        previous = token
    end

    return boundaries
end

-- Each tripwire is dead (`if false then ... end`), but its identifier, keys, and
-- values are drawn from the per-build PRNG so no fixed decoy signature (formerly
-- `_ad_static_`, `"branch"`, `"static-branch-"`) survives across builds for a
-- deobfuscator to fingerprint and strip.
local function tripwire(prng)
    local name = prng:identifier(prng:range(6, 12))
    local key = prng:identifier(prng:range(4, 8)):gsub("^_", "")
    local value = prng:identifier(prng:range(6, 12))
    return string.format(
        "if false then\n    local %s = {\n        [%q] = %q,\n        [%d] = %d\n    }\nend\n",
        name, key, value, prng:range(1, 97), prng:range(0, 1009))
end

function Step.apply(source, options)
    if type(source) ~= "string" then error(Step.name .. ": source must be a string") end
    options = options or {}
    if type(options) ~= "table" then error(Step.name .. ": options must be a table") end
    validate(source, "source")

    local max_tripwires = positive_option(options, "maxTripwires", 8)
    local max_bytes = positive_option(options, "maxBytes", 2048)
    local density = positive_option(options, "density", 240)
    -- A seed makes tripwires unique per build; without one a stable default keeps
    -- output deterministic for reproducible builds and tests.
    local prng = Entropy.prng(options.seed ~= nil and options.seed or "anti-deobfuscation")
    local shebang = source:match("^(#![^\n]*\n)") or ""
    local first_offset = #shebang + 1
    local body = source:sub(first_offset)
    local tokens = Lexer.scan(body)
    local boundaries = top_level_boundaries(body, tokens, 1)
    local requested = math.max(1, math.ceil(math.max(1, #body) / density))
    local count = math.min(max_tripwires, requested, #boundaries)
    local insertions, used = {}, 0

    for index = 1, count do
        local text = tripwire(prng)
        if used + #text > max_bytes then break end
        insertions[#insertions + 1] = { offset = boundaries[index], text = text }
        used = used + #text
    end

    for index = #insertions, 1, -1 do
        local insertion = insertions[index]
        body = body:sub(1, insertion.offset - 1) .. insertion.text .. body:sub(insertion.offset)
    end

    local result = shebang .. body
    validate(result, "result")
    Step.last_metadata = {
        tripwire_count = #insertions,
        generated_bytes = used,
        validated = true
    }
    return result
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
