local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")
local Entropy = require("src.core.entropy")

local Step = { name = "boolean-noise", version = 2 }
Step.metadata = {
    id = Step.name,
    version = Step.version,
    kind = "transformation",
    description = "Rewrites boolean literals to parenthesized, side-effect-free equivalent expressions."
}

-- Every entry is a parenthesised, side-effect-free expression evaluating to the
-- named boolean. Index 1 is the deterministic default used when no seed is given.
local truthy = { "(true and true)", "(not false)", "(1==1)", "(true or false)", "(not not true)" }
local falsy = { "(false or false)", "(not true)", "(1==0)", "(false and true)", "(not not false)" }

function Step.apply(source, options)
    if type(source) ~= "string" then error(Step.name .. ": source must be a string") end
    if options ~= nil and type(options) ~= "table" then error(Step.name .. ": options must be a table") end
    if #source > 1024 * 1024 then error(Step.name .. ": source exceeds the 1048576 byte limit") end
    local valid, message, position = Validate.syntax(source)
    if not valid then error(Step.name .. ": source is invalid at " .. position .. ": " .. message) end
    options = options or {}
    local max_replacements = options.max_replacements or 128
    local max_bytes = options.max_bytes or 8192
    if type(max_replacements) ~= "number" or max_replacements < 1 or max_replacements % 1 ~= 0 then error(Step.name .. ": max_replacements must be a positive integer") end
    if type(max_bytes) ~= "number" or max_bytes < 1 or max_bytes % 1 ~= 0 then error(Step.name .. ": max_bytes must be a positive integer") end
    if max_replacements > 100000 then error(Step.name .. ": max_replacements exceeds the hard limit") end
    if max_bytes > 65536 then error(Step.name .. ": max_bytes exceeds the hard limit") end
    -- A seed varies which equivalent expression each literal becomes, so no two
    -- builds share the same boolean-rewrite pattern; without one, the canonical
    -- first form is used for deterministic output.
    local prng = options.seed ~= nil and Entropy.prng(options.seed) or nil
    local output, cursor, count, added = {}, 1, 0, 0
    for _, token in ipairs(Lexer.scan(source)) do
        output[#output + 1] = source:sub(cursor, token.start - 1)
        local replacement
        if count < max_replacements and token.kind == "identifier" and token.value == "true" then
            replacement = prng and prng:pick(truthy) or truthy[1]
        elseif count < max_replacements and token.kind == "identifier" and token.value == "false" then
            replacement = prng and prng:pick(falsy) or falsy[1]
        else
            replacement = token.value
        end
        if replacement ~= token.value then
            local increase = #replacement - #token.value
            if added + increase > max_bytes then replacement = token.value else count = count + 1; added = added + increase end
        end
        output[#output + 1] = replacement
        cursor = token.finish + 1
    end
    output[#output + 1] = source:sub(cursor)
    local result = table.concat(output)
    valid, message, position = Validate.syntax(result)
    if not valid then error(Step.name .. ": generated source is invalid at " .. position .. ": " .. message) end
    Step.last_metadata = { replacement_count = count, generated_bytes = added, semantically_equivalent = true, validated = true }
    return result
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
