local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")
local Entropy = require("src.core.entropy")

local Step = { name = "opaque-predicates", version = 1 }
Step.metadata = {
    id = Step.name,
    version = Step.version,
    kind = "transformation",
    description = "Inserts bounded dead blocks guarded by opaque predicates that resist trivial static removal."
}

local function limit(options, name, default)
    local value = options[name]
    if value == nil then return default end
    if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
        error(Step.name .. ": " .. name .. " must be a positive integer")
    end
    return value
end

-- Opaque-FALSE predicates: each is provably always false, so the block it guards
-- is dead and semantics are preserved -- but a deobfuscator must reason about an
-- arithmetic or string invariant to prove it, instead of stripping `if false`.
local function opaque_false(prng)
    local kind = prng:range(1, 3)
    if kind == 1 then
        -- A string's length is never negative.
        return "#tostring(" .. prng:range(100, 999999) .. ") < 0"
    elseif kind == 2 then
        -- A perfect square mod 4 is only ever 0 or 1.
        local n = prng:range(3, 99999)
        return "(" .. n .. "*" .. n .. ")%" .. "4 == " .. (prng:range(0, 1) == 0 and 2 or 3)
    end
    -- The product of two consecutive integers is always even.
    local n = prng:range(3, 99999)
    return "(" .. n .. "*(" .. n .. "+1))%" .. "2 == 1"
end

local function value_expr(prng)
    local kind = prng:range(1, 3)
    if kind == 1 then return tostring(prng:range(0, 999999)) end
    if kind == 2 then return tostring(prng:range(0, 9999)) .. "+" .. tostring(prng:range(0, 9999)) end
    return "{" .. tostring(prng:range(0, 999)) .. "}"
end

function Step.apply(source, options)
    if type(source) ~= "string" then error(Step.name .. ": source must be a string") end
    if options ~= nil and type(options) ~= "table" then error(Step.name .. ": options must be a table") end
    options = options or {}
    if #source > 1024 * 1024 then error(Step.name .. ": source exceeds the 1048576 byte limit") end
    local valid, message, position = Validate.syntax(source)
    if not valid then error(Step.name .. ": source is invalid at " .. position .. ": " .. message) end
    local max_insertions = limit(options, "max_insertions", 6)
    local max_bytes = limit(options, "max_bytes", 4096)
    if max_insertions > 1024 then error(Step.name .. ": max_insertions exceeds the hard limit") end
    if max_bytes > 65536 then error(Step.name .. ": max_bytes exceeds the hard limit") end

    -- Always seeded (deterministic without an explicit seed); the obfuscator
    -- injects a per-build seed so each build differs.
    local prng = Entropy.prng(options.seed or "opaque-predicates")
    local shebang = source:match("^(#![^\n]*\n)") or ""
    local body = source:sub(#shebang + 1)
    local blocks, bytes = {}, 0
    for _ = 1, max_insertions do
        local text = "if " .. opaque_false(prng) .. " then local " ..
            prng:identifier(prng:range(6, 12)) .. " = " .. value_expr(prng) .. " end\n"
        if bytes + #text > max_bytes then break end
        blocks[#blocks + 1] = text
        bytes = bytes + #text
    end
    local result = shebang .. table.concat(blocks) .. body
    valid, message, position = Validate.syntax(result)
    if not valid then error(Step.name .. ": generated source is invalid at " .. position .. ": " .. message) end
    Step.last_metadata = { insertion_count = #blocks, generated_bytes = bytes, dead_only = true, validated = true }
    return result
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
