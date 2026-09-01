local Lexer = require("src.core.lexer")
local Entropy = require("src.core.entropy")

local Step = {}
Step.name = "junk-comments"
Step.version = 1
-- Inserting block comments between existing tokens only ever adds separators, so
-- the result stays valid and never needs re-lexing.
Step.emits_valid = true

-- Inspired by Luraph's junk-comment noise: sprinkle short block comments filled
-- with random non-ASCII glyphs between tokens. They are pure whitespace to the
-- parser but wreck pattern-based deobfuscators and beautifiers. Improvements over
-- the reference: bounded by a byte budget, seed-driven (unique per build), and
-- guaranteed never to contain `]]` or a newline (so it cannot close its own
-- comment or break single-line output).

-- Codepoint ranges that render as dense "garbage": CJK, arrows, box-drawing,
-- misc symbols, katakana. All are well above 0x5D, so none is a ']' or newline.
local RANGES = {
    { 0x4E00, 0x9FA0 }, { 0x2190, 0x21FF }, { 0x2500, 0x257F },
    { 0x2600, 0x26FF }, { 0x30A0, 0x30FF }, { 0x2460, 0x24FF },
}

local function utf8_encode(cp)
    if cp < 0x80 then return string.char(cp) end
    if cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    end
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local function junk(prng, glyphs)
    local parts = {}
    for index = 1, glyphs do
        local range = prng:pick(RANGES)
        parts[index] = utf8_encode(prng:range(range[1], range[2]))
    end
    return "--[[" .. table.concat(parts) .. "]]"
end

local function limit(options, name, default, hard)
    local value = options[name]
    if value == nil then return default end
    if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
        error("junk-comments: " .. name .. " must be a positive integer")
    end
    if value > hard then error("junk-comments: " .. name .. " exceeds the hard limit") end
    return value
end

function Step.apply(source, options)
    if type(source) ~= "string" then error("junk-comments: source must be a string") end
    if options ~= nil and type(options) ~= "table" then error("junk-comments: options must be a table") end
    options = options or {}
    local prng = Entropy.prng(options.seed or "junk-comments")
    local max_bytes = limit(options, "max_bytes", 8192, 262144)
    local density = options.density or 0.14
    if type(density) ~= "number" or density < 0 or density > 1 then
        error("junk-comments: density must be between 0 and 1")
    end

    local shebang = source:match("^(#![^\n]*\n)") or ""
    local body = source:sub(#shebang + 1)

    local out, cursor, budget = {}, 1, max_bytes
    for _, token in ipairs(Lexer.scan(body)) do
        -- Original span up to and including this token (comments included verbatim).
        out[#out + 1] = body:sub(cursor, token.finish)
        cursor = token.finish + 1
        -- A block comment between two tokens is only a separator, so it is always
        -- safe here. Skip when we would land mid-comment sequence anyway.
        if budget > 24 and prng:float() < density then
            -- Leading space so the comment can never merge with a preceding '-'
            -- into '---[[' (which Lua reads as a line comment and would swallow
            -- the rest of a single-line program).
            local piece = " " .. junk(prng, prng:range(4, 12))
            if #piece <= budget then
                out[#out + 1] = piece
                budget = budget - #piece
            end
        end
    end
    out[#out + 1] = body:sub(cursor)
    Step.last_metadata = { budget_used = max_bytes - budget, validated = true }
    return shebang .. table.concat(out)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
