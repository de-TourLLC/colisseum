local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")

local Step = { name = "dialect-guard", version = 1 }
Step.metadata = {
    id = Step.name,
    version = Step.version,
    kind = "validation",
    description = "Checks source structure and rejects syntax outside the selected Lua dialect."
}

local compound = { ["+="] = true, ["-="] = true, ["*="] = true, ["/="] = true, ["//="] = true, ["..="] = true }

local function option_target(options)
    if options == nil then return "lua" end
    if type(options) ~= "table" then error("dialect-guard: options must be a table") end
    local target = tostring(options.target or "lua"):lower()
    if target ~= "lua" and target ~= "luau" then error("dialect-guard: target must be 'lua' or 'luau'") end
    return target
end

function Step.apply(source, options)
    if type(source) ~= "string" then error("dialect-guard: source must be a string") end
    local target = option_target(options)
    local valid, message, position = Validate.syntax(source)
    if not valid then error("dialect-guard: invalid structure at " .. position .. ": " .. message) end

    local tokens, identifiers = Lexer.scan(source), 0
    for index, token in ipairs(tokens) do
        if token.kind == "identifier" then identifiers = identifiers + 1 end
        if target == "lua" and token.kind == "symbol" then
            local next_token = tokens[index + 1]
            local pair = token.value .. (next_token and next_token.value or "")
            if compound[pair] then error("dialect-guard: '" .. pair .. "' is not valid for Lua at " .. token.start) end
        end
    end
    Step.last_metadata = { target = target, token_count = #tokens, identifier_count = identifiers, validated = true }
    return source
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
