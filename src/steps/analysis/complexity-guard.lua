local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")

local Step = { name = "complexity-guard", version = 1 }
Step.metadata = {
    id = Step.name, version = Step.version, kind = "validation",
    description = "Measures lexical nesting and control-flow complexity against explicit limits."
}

local defaults = { tokens = 10000, nesting = 100, control_flow = 1000 }
local controls = { ["if"] = true, ["for"] = true, ["while"] = true, ["repeat"] = true, ["function"] = true }

local function limit(options, key)
    local value = options[key]
    if value == nil then return defaults[key] end
    if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then error("complexity-guard: " .. key .. " limit must be a positive integer") end
    return value
end

function Step.apply(source, options)
    if type(source) ~= "string" then error("complexity-guard: source must be a string") end
    if options ~= nil and type(options) ~= "table" then error("complexity-guard: options must be a table") end
    options = options or {}
    local valid, message, position = Validate.syntax(source)
    if not valid then error("complexity-guard: invalid structure at " .. position .. ": " .. message) end
    local token_limit, nesting_limit, flow_limit = limit(options, "tokens"), limit(options, "nesting"), limit(options, "control_flow")
    local tokens, depth, maximum, flow = Lexer.scan(source), 0, 0, 0
    for _, token in ipairs(tokens) do
        if token.kind == "identifier" and controls[token.value] then flow = flow + 1 end
        if token.kind == "symbol" and (token.value == "(" or token.value == "[" or token.value == "{") then
            depth = depth + 1; if depth > maximum then maximum = depth end
        elseif token.kind == "symbol" and (token.value == ")" or token.value == "]" or token.value == "}") then depth = depth - 1 end
    end
    if #tokens > token_limit then error("complexity-guard: token budget exceeded (" .. #tokens .. "/" .. token_limit .. ")") end
    if maximum > nesting_limit then error("complexity-guard: nesting limit exceeded (" .. maximum .. "/" .. nesting_limit .. ")") end
    if flow > flow_limit then error("complexity-guard: control-flow limit exceeded (" .. flow .. "/" .. flow_limit .. ")") end
    Step.last_metadata = { token_count = #tokens, maximum_nesting = maximum, control_flow_count = flow, validated = true }
    return source
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
