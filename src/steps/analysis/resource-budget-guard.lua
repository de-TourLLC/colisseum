local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")

local Step = { name = "resource-budget-guard", version = 1 }
Step.metadata = {
    id = Step.name, version = Step.version, kind = "validation",
    description = "Rejects source exceeding bounded bytes, lines, literals, or lexical nesting budgets."
}

local defaults = { bytes = 1024 * 1024, lines = 20000, literals = 10000, nesting = 1000 }
local function budget(options, key)
    local value = options[key]
    if value == nil then return defaults[key] end
    if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then error("resource-budget-guard: " .. key .. " budget must be a positive integer") end
    return value
end

function Step.apply(source, options)
    if type(source) ~= "string" then error("resource-budget-guard: source must be a string") end
    if options ~= nil and type(options) ~= "table" then error("resource-budget-guard: options must be a table") end
    options = options or {}
    local valid, message, position = Validate.syntax(source)
    if not valid then error("resource-budget-guard: invalid structure at " .. position .. ": " .. message) end
    local bytes, lines, literal_limit, nesting_limit = budget(options, "bytes"), budget(options, "lines"), budget(options, "literals"), budget(options, "nesting")
    local tokens, literals, depth, maximum = Lexer.scan(source), 0, 0, 0
    for _, token in ipairs(tokens) do
        if token.kind == "string" or token.kind == "number" then literals = literals + 1 end
        if token.kind == "symbol" and (token.value == "(" or token.value == "[" or token.value == "{") then depth = depth + 1; if depth > maximum then maximum = depth end
        elseif token.kind == "symbol" and (token.value == ")" or token.value == "]" or token.value == "}") then depth = depth - 1 end
    end
    local line_count = select(2, source:gsub("\n", "")) + 1
    if #source > bytes then error("resource-budget-guard: byte budget exceeded (" .. #source .. "/" .. bytes .. ")") end
    if line_count > lines then error("resource-budget-guard: line budget exceeded (" .. line_count .. "/" .. lines .. ")") end
    if literals > literal_limit then error("resource-budget-guard: literal budget exceeded (" .. literals .. "/" .. literal_limit .. ")") end
    if maximum > nesting_limit then error("resource-budget-guard: nesting budget exceeded (" .. maximum .. "/" .. nesting_limit .. ")") end
    Step.last_metadata = { byte_count = #source, line_count = line_count, literal_count = literals, maximum_nesting = maximum, validated = true }
    return source
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
