local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")

local Step = { name = "visual-noise", version = 1 }
Step.metadata = {
    id = Step.name,
    version = Step.version,
    kind = "transformation",
    description = "Adds bounded blank lines only in existing whitespace gaps, preserving every token."
}

function Step.apply(source, options)
    if type(source) ~= "string" then error(Step.name .. ": source must be a string") end
    if options ~= nil and type(options) ~= "table" then error(Step.name .. ": options must be a table") end
    if #source > 1024 * 1024 then error(Step.name .. ": source exceeds the 1048576 byte limit") end
    local valid, message, position = Validate.syntax(source)
    if not valid then error(Step.name .. ": source is invalid at " .. position .. ": " .. message) end
    options = options or {}
    local max_insertions = options.max_insertions or 32
    local max_bytes = options.max_bytes or 1024
    if type(max_insertions) ~= "number" or max_insertions < 1 or max_insertions % 1 ~= 0 then error(Step.name .. ": max_insertions must be a positive integer") end
    if type(max_bytes) ~= "number" or max_bytes < 1 or max_bytes % 1 ~= 0 then error(Step.name .. ": max_bytes must be a positive integer") end
    if max_insertions > 4096 then error(Step.name .. ": max_insertions exceeds the hard limit") end
    if max_bytes > 65536 then error(Step.name .. ": max_bytes exceeds the hard limit") end
    local tokens, output, cursor, count, added = Lexer.scan(source), {}, 1, 0, 0
    for _, token in ipairs(tokens) do
        local gap = source:sub(cursor, token.start - 1)
        if count < max_insertions and gap:find("\n", 1, true) and added < max_bytes then
            gap = gap .. "\n"
            count = count + 1
            added = added + 1
        end
        output[#output + 1] = gap .. token.value
        cursor = token.finish + 1
    end
    local tail = source:sub(cursor)
    if count < max_insertions and tail:find("\n", 1, true) and added < max_bytes then tail = tail .. "\n"; count = count + 1; added = added + 1 end
    output[#output + 1] = tail
    local result = table.concat(output)
    valid, message, position = Validate.syntax(result)
    if not valid then error(Step.name .. ": generated source is invalid at " .. position .. ": " .. message) end
    local result_tokens = Lexer.scan(result)
    if #result_tokens ~= #tokens then error(Step.name .. ": token integrity check failed") end
    for index, token in ipairs(tokens) do
        if token.kind ~= result_tokens[index].kind or token.value ~= result_tokens[index].value then error(Step.name .. ": token integrity check failed") end
    end
    Step.last_metadata = { insertion_count = count, generated_bytes = added, tokens_preserved = true, validated = true }
    return result
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
