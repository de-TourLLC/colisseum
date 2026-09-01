local Lexer = require("src.core.lexer")
local Entropy = require("src.core.entropy")

local Step = {}
Step.name = "numbers"
Step.version = 2

-- Recursively rewrites an integer
-- literal into an equivalent arithmetic expression (a+b or (x)-y), so the value
-- never appears literally. Implemented natively at the token level with
-- Colisseum's per-build PRNG. Pure integer arithmetic keeps the result exact.
local RANGE = 1048576 -- 2^20, matching the reference; well within exact-double range
local SAFE = 2 ^ 52

local function build_expr(prng, value, depth)
    -- Base case: emit the literal (parenthesised when negative so it never forms
    -- an ambiguous "+-" / "--" adjacency with a preceding operator).
    if depth <= 0 or prng:float() > 0.55 then
        if value < 0 then return "(" .. tostring(value) .. ")" end
        return tostring(value)
    end
    if prng:range(0, 1) == 0 then
        local a = prng:range(-RANGE, RANGE)          -- a + b == value
        return "(" .. build_expr(prng, a, depth - 1) .. "+" .. build_expr(prng, value - a, depth - 1) .. ")"
    end
    local a = prng:range(-RANGE, RANGE)              -- (value + a) - a == value
    return "(" .. build_expr(prng, value + a, depth - 1) .. "-" .. build_expr(prng, a, depth - 1) .. ")"
end

function Step.apply(source, options)
    if type(source) ~= "string" then error("numbers: source must be a string") end
    if options ~= nil and type(options) ~= "table" then error("numbers: options must be a table") end
    options = options or {}
    -- A seed drives per-build-unique expressions; without one, fall back to the
    -- deterministic parenthesised form so unit tests stay stable.
    local prng = options.seed ~= nil and Entropy.prng(options.seed) or nil
    local tokens = Lexer.scan(source)
    local out, cursor = {}, 1
    for index = 1, #tokens do
        local token = tokens[index]
        if token.kind == "number" then
            out[#out + 1] = source:sub(cursor, token.start - 1)
            local value = tonumber(token.value)
            local plain_integer = value and value == math.floor(value)
                and math.abs(value) < SAFE and not token.value:find("[%.eExX]")
            if prng and plain_integer then
                out[#out + 1] = build_expr(prng, value, prng:range(2, 4))
            else
                out[#out + 1] = "(" .. token.value .. ")"
            end
            cursor = token.finish + 1
        end
    end
    out[#out + 1] = source:sub(cursor)
    return table.concat(out)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
