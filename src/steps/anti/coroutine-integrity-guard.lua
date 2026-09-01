local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")

local Step = { name = "coroutine-integrity-guard", version = 1 }
Step.metadata = {
    id = Step.name,
    version = Step.version,
    kind = "analysis",
    description = "Analyzes coroutine references without rewriting runtime behavior."
}

local names = { coroutine = true, create = true, resume = true, running = true, status = true, wrap = true, yield = true, isyieldable = true }

function Step.apply(source, options)
    if type(source) ~= "string" then error(Step.name .. ": source must be a string") end
    if options ~= nil and type(options) ~= "table" then error(Step.name .. ": options must be a table") end
    if #source > 1024 * 1024 then error(Step.name .. ": source exceeds the 1048576 byte limit") end
    local valid, message, position = Validate.syntax(source)
    if not valid then error(Step.name .. ": source is invalid at " .. position .. ": " .. message) end
    options = options or {}
    local max_tokens = options.max_tokens or 100000
    local max_references = options.max_references or 1024
    if type(max_tokens) ~= "number" or max_tokens < 1 or max_tokens % 1 ~= 0 then error(Step.name .. ": max_tokens must be a positive integer") end
    if type(max_references) ~= "number" or max_references < 1 or max_references % 1 ~= 0 then error(Step.name .. ": max_references must be a positive integer") end
    if max_tokens > 1000000 then error(Step.name .. ": max_tokens exceeds the hard limit") end
    if max_references > 100000 then error(Step.name .. ": max_references exceeds the hard limit") end
    local tokens = Lexer.scan(source)
    if #tokens > max_tokens then error(Step.name .. ": token budget exceeded") end
    local references = 0
    for _, token in ipairs(tokens) do
        if token.kind == "identifier" and names[token.value] then
            references = references + 1
            if references > max_references then error(Step.name .. ": coroutine reference budget exceeded") end
        end
    end
    Step.last_metadata = { coroutine_references = references, token_count = #tokens, analysis_only = true, runtime_behavior_untouched = true, validated = true }
    return source
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
