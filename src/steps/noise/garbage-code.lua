local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")
local Entropy = require("src.core.entropy")
local Safe = require("src.steps.shared.token-safe")

local Step = { name = "garbage-code", version = 3 }
Step.metadata = {
    id = Step.name,
    version = Step.version,
    kind = "transformation",
    description = "Adds bounded, unreachable local statements without executing generated code."
}

local function limit(options, name, default)
    local value = options[name]
    if value == nil then return default end
    if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
        error(Step.name .. ": " .. name .. " must be a positive integer")
    end
    return value
end

local function check_source(source)
    if type(source) ~= "string" then error(Step.name .. ": source must be a string") end
    if #source > 1024 * 1024 then error(Step.name .. ": source exceeds the 1048576 byte limit") end
    local valid, message, position = Validate.syntax(source)
    if not valid then error(Step.name .. ": source is invalid at " .. position .. ": " .. message) end
end

-- Unreachable wrappers. Varying the guard keeps the injected noise from carrying
-- a single recognisable signature across builds. The literal-false forms are
-- joined by several runtime-always-false guards (`n*0 ~= 0`, `x ~= x`, an ordered
-- pair contradiction) so the block is not always a grep-able `if false then`.
-- Every wrapped body is a harmless local assignment, so even a guard that somehow
-- evaluated true could not change observable behaviour.
local guards = {
    function(body) return "if false then " .. body .. " end" end,
    function(body) return "while false do " .. body .. " end" end,
    function(body, prng) return "for " .. prng:identifier(prng:range(4, 6)) .. "=1,0 do " .. body .. " end" end,
    function(body, prng)
        local n = prng:identifier(prng:range(4, 6))
        return "do local " .. n .. "=" .. tostring(prng:range(2, 9999)) ..
            " if (" .. n .. "*0)~=0 then " .. body .. " end end"
    end,
    function(body, prng)
        local n = prng:identifier(prng:range(4, 6))
        return "do local " .. n .. "=" .. tostring(prng:range(2, 9999)) ..
            " if " .. n .. "~=" .. n .. " then " .. body .. " end end"
    end,
    function(body, prng)
        local lo = prng:range(1, 4000)
        local hi = lo + prng:range(1, 4000)
        local p, q = prng:identifier(prng:range(4, 6)), prng:identifier(prng:range(4, 6))
        return "do local " .. p .. "," .. q .. "=" .. tostring(lo) .. "," .. tostring(hi) ..
            " if " .. p .. ">" .. q .. " then " .. body .. " end end"
    end,
}

-- Side-effect-free, semantically inert right-hand sides.
local function value_expr(prng)
    local kind = prng:range(1, 6)
    if kind == 1 then
        return tostring(prng:range(0, 999999))
    elseif kind == 2 then
        return tostring(prng:range(0, 9999)) .. "+" .. tostring(prng:range(0, 9999))
    elseif kind == 3 then
        return prng:range(0, 1) == 0 and "true" or "false"
    elseif kind == 4 then
        return "(" .. tostring(prng:range(1, 9999)) .. "*" .. tostring(prng:range(2, 97)) ..
            ")%" .. tostring(prng:range(257, 65521))
    elseif kind == 5 then
        return "{" .. tostring(prng:range(0, 999)) .. "," .. tostring(prng:range(0, 999)) ..
            ",[" .. tostring(prng:range(1, 99)) .. "]=" .. tostring(prng:range(0, 999)) .. "}"
    end
    return "{" .. tostring(prng:range(0, 999)) .. "," .. tostring(prng:range(0, 999)) .. "}"
end

function Step.apply(source, options)
    if options ~= nil and type(options) ~= "table" then error(Step.name .. ": options must be a table") end
    options = options or {}
    check_source(source)
    local max_insertions = limit(options, "max_insertions", 8)
    local max_bytes = limit(options, "max_bytes", 4096)
    if max_insertions > 1024 then error(Step.name .. ": max_insertions exceeds the hard limit") end
    if max_bytes > 65536 then error(Step.name .. ": max_bytes exceeds the hard limit") end
    local shebang = source:match("^(#![^\n]*\n)") or ""
    local body = source:sub(#shebang + 1)
    -- Always drive the injected noise from a PRNG: without one the fallback would
    -- emit a fixed `_colisseum_dead_N` prefix that a regex could strip on sight.
    local prng = Entropy.prng(options.seed or "garbage-code")
    local blocks, bytes = {}, 0
    for index = 1, max_insertions do
        local statement = "local " .. prng:identifier(prng:range(6, 12)) .. " = " .. value_expr(prng)
        -- Frame each block with its own leading/trailing newline so it can never
        -- fuse with a neighbouring token when spliced at a statement boundary.
        local text = "\n" .. prng:pick(guards)(statement, prng) .. "\n"
        if bytes + #text > max_bytes then break end
        blocks[#blocks + 1] = text
        bytes = bytes + #text
    end
    -- Scatter the dead blocks across random top-level statement boundaries instead
    -- of stacking them into one contiguous prefix a deobfuscator could strip in a
    -- single cut. Fall back to a prefix splice if interleaving somehow invalidates.
    local result = shebang .. Safe.interleave(body, prng, blocks)
    local valid, message, position = Validate.syntax(result)
    if not valid then
        result = shebang .. table.concat(blocks) .. body
        valid, message, position = Validate.syntax(result)
        if not valid then error(Step.name .. ": generated source is invalid at " .. position .. ": " .. message) end
    end
    Step.last_metadata = { insertion_count = #blocks, generated_bytes = bytes, dead_only = true, validated = true }
    return result
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
