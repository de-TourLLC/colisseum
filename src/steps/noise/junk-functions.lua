local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")
local Entropy = require("src.core.entropy")

local Step = { name = "junk-functions", version = 1 }
Step.metadata = {
    id = Step.name,
    version = Step.version,
    kind = "transformation",
    description = "Adds bounded, never-called dead decoy functions."
}

-- Reject anything that is not a positive integer, mirroring garbage-code's
-- `limit` helper so the two noise steps validate their options identically.
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

-- Side-effect-free right-hand sides. Every branch is a pure literal or an
-- arithmetic combination of the function's own prior locals, so a body can be
-- read as plausible logic yet can never touch a global, call anything, or fail.
local function value_expr(prng, priors)
    local kind = prng:range(1, 5)
    if kind == 1 then
        return tostring(prng:range(0, 999999))
    elseif kind == 2 then
        return tostring(prng:range(0, 9999)) .. " + " .. tostring(prng:range(0, 9999))
    elseif kind == 3 then
        return prng:range(0, 1) == 0 and "true" or "false"
    elseif kind == 4 then
        return "{" .. tostring(prng:range(0, 999)) .. ", " .. tostring(prng:range(0, 999)) .. "}"
    end
    -- Reference an earlier local when one exists; this keeps the body wholly
    -- self-contained (only its own locals) while looking like real dataflow.
    if priors and #priors > 0 then
        return priors[prng:range(1, #priors)] .. " + " .. tostring(prng:range(1, 99))
    end
    return tostring(prng:range(0, 999))
end

-- Build one dead `local function`. It declares between one and four locals from
-- pure values and returns one of them. Defining it has no side effect, and the
-- step never emits a call to it, so the body is unreachable at runtime.
local function build_function(prng)
    local name = prng:identifier(prng:range(6, 12))
    local locals, lines = {}, {}
    local count = prng:range(1, 4)
    for _ = 1, count do
        local var = prng:identifier(prng:range(6, 12))
        lines[#lines + 1] = "    local " .. var .. " = " .. value_expr(prng, locals)
        locals[#locals + 1] = var
    end
    lines[#lines + 1] = "    return " .. locals[prng:range(1, #locals)]
    return "local function " .. name .. "()\n" .. table.concat(lines, "\n") .. "\nend\n"
end

function Step.apply(source, options)
    if options ~= nil and type(options) ~= "table" then error(Step.name .. ": options must be a table") end
    options = options or {}
    check_source(source)
    local max_functions = limit(options, "max_functions", 3)
    local max_bytes = limit(options, "max_bytes", 4096)
    if max_functions > 64 then error(Step.name .. ": max_functions exceeds the hard limit") end
    if max_bytes > 65536 then error(Step.name .. ": max_bytes exceeds the hard limit") end
    -- Deterministic given a seed; different seeds yield different decoys. A
    -- fixed default keeps the step reproducible when no seed is supplied.
    local prng = Entropy.prng(options.seed or "junk-functions")
    local shebang = source:match("^(#![^\n]*\n)") or ""
    local body = source:sub(#shebang + 1)
    local blocks, bytes = {}, 0
    for _ = 1, max_functions do
        local text = build_function(prng)
        if bytes + #text > max_bytes then break end
        blocks[#blocks + 1] = text
        bytes = bytes + #text
    end
    local result = shebang .. table.concat(blocks) .. body
    local valid, message, position = Validate.syntax(result)
    if not valid then error(Step.name .. ": generated source is invalid at " .. position .. ": " .. message) end
    Step.last_metadata = { function_count = #blocks, generated_bytes = bytes, dead_only = true, validated = true }
    return result
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
