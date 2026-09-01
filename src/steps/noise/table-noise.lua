local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")
local Entropy = require("src.core.entropy")

local Step = { name = "table-noise", version = 2 }
Step.metadata = {
    id = Step.name,
    version = Step.version,
    kind = "transformation",
    description = "Adds one bounded unreachable local table containing only static values."
}

local function positive(options, name, default)
    local value = options[name]
    if value == nil then return default end
    if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
        error(Step.name .. ": " .. name .. " must be a positive integer")
    end
    return value
end

function Step.apply(source, options)
    if type(source) ~= "string" then error(Step.name .. ": source must be a string") end
    if options ~= nil and type(options) ~= "table" then error(Step.name .. ": options must be a table") end
    if #source > 1024 * 1024 then error(Step.name .. ": source exceeds the 1048576 byte limit") end
    local valid, message, position = Validate.syntax(source)
    if not valid then error(Step.name .. ": source is invalid at " .. position .. ": " .. message) end
    options = options or {}
    local entries = positive(options, "max_entries", 8)
    local max_bytes = positive(options, "max_bytes", 2048)
    if entries > 1024 then error(Step.name .. ": max_entries exceeds the hard limit") end
    if max_bytes > 65536 then error(Step.name .. ": max_bytes exceeds the hard limit") end
    -- A seed randomises the table name and its static contents per build so the
    -- injected table carries no fixed signature; without one it is deterministic.
    local prng = options.seed ~= nil and Entropy.prng(options.seed) or nil
    local name = prng and prng:identifier(prng:range(6, 12)) or "_colisseum_table_noise"
    local fields = {}
    for index = 1, entries do
        local value = prng and tostring(prng:range(0, 999999)) or tostring(index * 31)
        fields[#fields + 1] = "        [" .. index .. "] = " .. value
    end
    local guard_open, guard_close = "if false then", "end"
    if prng and prng:range(0, 1) == 1 then guard_open, guard_close = "while false do", "end" end
    local text = guard_open .. "\n    local " .. name .. " = {\n" .. table.concat(fields, ",\n") .. "\n    }\n" .. guard_close .. "\n"
    if #text > max_bytes then text = "" end
    local shebang = source:match("^(#![^\n]*\n)") or ""
    local result = shebang .. text .. source:sub(#shebang + 1)
    valid, message, position = Validate.syntax(result)
    if not valid then error(Step.name .. ": generated source is invalid at " .. position .. ": " .. message) end
    Step.last_metadata = { entry_count = text == "" and 0 or entries, generated_bytes = #text, dead_local_table = true, validated = true }
    return result
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
