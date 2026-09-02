local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")
local Entropy = require("src.core.entropy")

local Step = { name = "opaque-predicates", version = 2 }
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
-- arithmetic, float, or type invariant to prove it, instead of stripping `if false`.
-- Mixing several families means no single constant-folding rule kills them all.
-- Families reference a RUNTIME value (os.time()/os.clock()), so the predicate is
-- not constant-foldable from the bundle: proving it false requires modeling the
-- standard library, not just evaluating integer literals.
local function opaque_false(prng)
    local kind = prng:range(1, 6)
    if kind == 1 then
        -- os.time() is a positive integer; its decimal string is never empty.
        return '#tostring(os.time()) < 0'
    elseif kind == 2 then
        -- os.time() % 2 is 0 or 1, never 3.
        return 'os.time()%2 == 3'
    elseif kind == 3 then
        -- os.clock() is a number, never a string.
        return 'type(os.clock()) == "string"'
    elseif kind == 4 then
        -- os.time() is a number, never a boolean.
        return 'type(os.time()) == "boolean"'
    elseif kind == 5 then
        -- os.clock() >= 0 always.
        return 'os.clock() < 0'
    end
    -- `type` of a number literal is always "number", never "userdata".
    return 'type(' .. prng:range(-9999, 9999) .. ') == "userdata"'
end

local function value_expr(prng)
    local kind = prng:range(1, 3)
    if kind == 1 then return tostring(prng:range(0, 999999)) end
    if kind == 2 then return tostring(prng:range(0, 9999)) .. "+" .. tostring(prng:range(0, 9999)) end
    return "{" .. tostring(prng:range(0, 999)) .. "}"
end

-- Collect every safe top-level insertion point (the prefix plus each statement
-- boundary) and distribute the dead blocks across random distinct points, so a
-- deobfuscator cannot strip a single contiguous "noise prefix".
local function insertion_points(body, prng, count)
    local tokens = Lexer.scan(body)
    local points = { 1 }
    local depth = 0
    for index, token in ipairs(tokens) do
        local prev = tokens[index - 1]
        if prev and token.start > 1 and depth == 0 and (prev.value == ";" or prev.value == "end" or prev.value == "until") then
            points[#points + 1] = token.start
        end
        local value = token.value
        if value == "then" or value == "do" or value == "function" or value == "repeat" then
            depth = depth + 1
        elseif value == "end" or value == "until" then
            if depth > 0 then depth = depth - 1 end
        end
    end
    for ii = #points, 2, -1 do
        local jj = prng:range(1, ii)
        points[ii], points[jj] = points[jj], points[ii]
    end
    if count >= #points then return points end
    local chosen = {}
    for ii = 1, count do chosen[ii] = points[ii] end
    table.sort(chosen)
    return chosen
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
        -- Leading newline so the block can never fuse with the previous token
        -- (e.g. `end`+`if` -> `endif`, or `return s`+`if` -> `return sif`): the
        -- dead block is spliced at a proven statement boundary, but the boundary
        -- check alone cannot guarantee a whitespace-free minified neighbor.
        local text = "\nif " .. opaque_false(prng) .. " then local " ..
            prng:identifier(prng:range(6, 12)) .. " = " .. value_expr(prng) .. " end\n"
        if bytes + #text > max_bytes then break end
        blocks[#blocks + 1] = text
        bytes = bytes + #text
    end
    -- Interleave the dead blocks at random top-level statement boundaries so the
    -- guard region is not a single trivially strippable prefix. Each insertion is
    -- at a proven statement boundary, so splicing cannot corrupt the program.
    local result
    if #blocks > 0 then
        local points = insertion_points(body, prng, #blocks)
        local parts, cursor = {}, 1
        for index, text in ipairs(blocks) do
            local at = points[index]
            if at ~= nil and at >= cursor then
                parts[#parts + 1] = body:sub(cursor, at - 1)
                parts[#parts + 1] = text
                cursor = at
            else
                parts[#parts + 1] = body:sub(cursor)
                parts[#parts + 1] = text
                parts[#parts + 1] = ""
                cursor = #body + 1
            end
        end
        parts[#parts + 1] = body:sub(cursor)
        result = shebang .. table.concat(parts)
    else
        result = source
    end
    valid, message, position = Validate.syntax(result)
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