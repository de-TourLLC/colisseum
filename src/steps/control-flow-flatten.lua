local Parser = require("src.core.parser")
local Validate = require("src.core.validate")
local Entropy = require("src.core.entropy")

local Step = { name = "control-flow-flatten", version = 2 }
Step.metadata = {
    id = Step.name,
    version = Step.version,
    kind = "transformation",
    description = "Flattens top-level control flow into a shuffled state-machine dispatcher."
}

-- Any construct this step is not certain it can flatten without changing meaning
-- makes it return the source unchanged. Correctness first: a no-op is always safe.

local function local_names(statement)
    local names = {}
    for _, entry in ipairs(statement.names or {}) do
        local name = type(entry) == "table" and (entry.name or entry.value) or entry
        if type(name) ~= "string" then return nil end
        names[#names + 1] = name
    end
    return names
end

-- True if `name` appears as an identifier anywhere in `text` (word-bounded).
local function references(text, name)
    return text:find("%f[%w_]" .. name .. "%f[^%w_]") ~= nil
end

-- Encode a state transition so the target state is not a plain literal a regex can
-- collect (`dispatch=N` -> edge sources). All three forms evaluate to exactly `value`
-- while hiding it behind trivial arithmetic; the state graph is still recoverable
-- by executing the chunk, but a textual scan can no longer map edges directly.
local function encode_transition(prng, value)
    local kind = prng:range(1, 3)
    if kind == 1 then return tostring(value) end
    if kind == 2 then return tostring(value) .. "+0" end
    -- v*2 - v - (v - v) == v
    return tostring(value * 2) .. "-" .. tostring(value) .. "-(" .. tostring(value) .. "-" .. tostring(value) .. ")"
end

function Step.apply(source, options)
    if type(source) ~= "string" then error(Step.name .. ": source must be a string") end
    if options ~= nil and type(options) ~= "table" then error(Step.name .. ": options must be a table") end
    options = options or {}
    local prng = Entropy.prng(options.seed or "control-flow-flatten")

    local shebang = source:match("^(#![^\n]*\n)") or ""
    local body = source:sub(#shebang + 1)

    local ok, ast = pcall(Parser.parse, body)
    if not ok or type(ast) ~= "table" or ast.kind ~= "chunk" or type(ast.body) ~= "table" then
        return source
    end
    local statements = ast.body
    if #statements < 2 then return source end

    local states = {}
    local hoist, hoisted = {}, {}

    local function hoist_name(name, before_offset)
        -- Reject shadowing (same name hoisted twice) and any earlier reference to
        -- the name (a prior closure may capture the global of the same name).
        if hoisted[name] then return false end
        if references(body:sub(1, before_offset - 1), name) then return false end
        hoisted[name] = true
        hoist[#hoist + 1] = name
        return true
    end

    for index, statement in ipairs(statements) do
        local text = body:sub(statement.start, statement.finish)
        local kind = statement.kind
        -- The parser does not always bound statements that contain function
        -- expressions tightly (it can split `local f = function() ... end`). Verify
        -- each extracted statement compiles on its own with the real Lua parser; if
        -- any fragment does not, the boundaries are unsafe, so leave source as-is.
        local valid = Validate.syntax(text)
        if not valid then return source end
        if kind == "return" then
            states[index] = { body = text, terminal = true }
        elseif kind == "local" then
            local names = local_names(statement)
            if not names then return source end
            for _, name in ipairs(names) do
                if not hoist_name(name, statement.start) then return source end
            end
            if statement.values and #statement.values > 0 then
                states[index] = { body = (text:gsub("^local%s+", "", 1)) }
            else
                states[index] = { body = nil }
            end
        elseif kind == "function" then
            local local_fn = text:match("^local%s+function%s+([%w_]+)")
            if local_fn then
                if not hoist_name(local_fn, statement.start) then return source end
                states[index] = { body = (text:gsub("^local%s+function%s+([%w_]+)", "%1 = function", 1)) }
            else
                states[index] = { body = text }
            end
        elseif kind == "assign" or kind == "expression" or kind == "if" or kind == "for"
            or kind == "numericfor" or kind == "genericfor" or kind == "while"
            or kind == "repeat" or kind == "do" then
            states[index] = { body = text }
        else
            return source
        end
    end

    -- A dispatcher variable that appears nowhere in the source and is not hoisted.
    local dispatch
    repeat dispatch = prng:identifier(prng:range(6, 10))
    until not body:find(dispatch, 1, true) and not hoisted[dispatch]

    -- Shuffle the physical order of the branches; the state transitions still run
    -- the statements in their original logical order.
    local order = {}
    for index = 1, #states do order[index] = index end
    for index = #order, 2, -1 do
        local swap = prng:range(1, index)
        order[index], order[swap] = order[swap], order[index]
    end

    local parts = {}
    if #hoist > 0 then parts[#parts + 1] = "local " .. table.concat(hoist, ",") .. "\n" end
    parts[#parts + 1] = "local " .. dispatch .. "=1\n"
    parts[#parts + 1] = "while " .. dispatch .. "~=0 do\n"
    for position, index in ipairs(order) do
        local state = states[index]
        local branch = (position == 1 and "if " or "elseif ") .. dispatch .. "==" .. index .. " then "
        if state.terminal then
            branch = branch .. (state.body or "return")
        else
            local nxt = index < #states and index + 1 or 0
            branch = branch .. (state.body and (state.body .. " ") or "") .. dispatch .. "=" .. encode_transition(prng, nxt)
        end
        parts[#parts + 1] = branch .. "\n"
    end
    -- Dead states: unreachable sentinel branches (the dispatcher never sets these
    -- values) carrying harmless local declarations and empty transitions. They add
    -- noise edges to the recovery graph and confuse naive state enumeration without
    -- ever executing or changing the program's behavior.
    local fake_count = prng:range(1, 2)
    for _ = 1, fake_count do
        local sentinel = #states + _
        local dead = "elseif " .. dispatch .. "==" .. sentinel .. " then local " ..
            prng:identifier(prng:range(6, 10)) .. "=" .. prng:range(0, 9999) .. " " ..
            dispatch .. "=" .. encode_transition(prng, sentinel) .. "\n"
        parts[#parts + 1] = dead
    end
    parts[#parts + 1] = "end\n" -- close the if/elseif chain
    parts[#parts + 1] = "end\n" -- close the while loop

    local result = shebang .. table.concat(parts)
    if not Validate.syntax(result) then return source end
    return result
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
