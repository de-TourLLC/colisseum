local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")
local Entropy = require("src.core.entropy")

local Step = { name = "garbage-code", version = 2 }
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

-- Statically unreachable wrappers. Varying the guard keeps the injected noise
-- from carrying a single recognisable signature across builds.
local guards = {
    function(body) return "if false then " .. body .. " end\n" end,
    function(body) return "while false do " .. body .. " end\n" end,
    function(body, prng) return "for " .. prng:identifier(prng:range(4, 6)) .. "=1,0 do " .. body .. " end\n" end,
}

-- Side-effect-free, semantically inert right-hand sides.
local function value_expr(prng)
    local kind = prng:range(1, 4)
    if kind == 1 then
        return tostring(prng:range(0, 999999))
    elseif kind == 2 then
        return tostring(prng:range(0, 9999)) .. "+" .. tostring(prng:range(0, 9999))
    elseif kind == 3 then
        return prng:range(0, 1) == 0 and "true" or "false"
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
    -- A seed makes the injected noise unique per build (names, values, guards);
    -- without one the step stays deterministic for reproducible, testable output.
    local prng = options.seed ~= nil and Entropy.prng(options.seed) or nil
    local blocks, bytes = {}, 0
    for index = 1, max_insertions do
        local text
        if prng then
            local statement = "local " .. prng:identifier(prng:range(6, 12)) .. " = " .. value_expr(prng)
            text = prng:pick(guards)(statement, prng)
        else
            text = "if false then\n    local _colisseum_dead_" .. index .. " = " .. (index * 17) .. "\nend\n"
        end
        if bytes + #text > max_bytes then break end
        blocks[#blocks + 1] = text
        bytes = bytes + #text
    end
    local result = shebang .. table.concat(blocks) .. body
    local valid, message, position = Validate.syntax(result)
    if not valid then error(Step.name .. ": generated source is invalid at " .. position .. ": " .. message) end
    Step.last_metadata = { insertion_count = #blocks, generated_bytes = bytes, dead_only = true, validated = true }
    return result
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
