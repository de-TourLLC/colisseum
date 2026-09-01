local Lexer = require("src.core.lexer")
local Parser = require("src.core.parser")
local Validate = require("src.core.validate")

local Step = { name = "unsupported-syntax-guard", version = 1 }
Step.metadata = {
    id = Step.name, version = Step.version, kind = "validation",
    description = "Parses source with Colisseum's supported grammar and reports unsupported constructs."
}

function Step.apply(source, options)
    if type(source) ~= "string" then error("unsupported-syntax-guard: source must be a string") end
    if options ~= nil and type(options) ~= "table" then error("unsupported-syntax-guard: options must be a table") end
    local valid, message, position = Validate.syntax(source)
    if not valid then error("unsupported-syntax-guard: invalid structure at " .. position .. ": " .. message) end
    local tokens = Lexer.scan(source)
    for index, token in ipairs(tokens) do
        if token.kind == "identifier" and (token.value == "break" or token.value == "goto" or token.value == "continue") then
            error("unsupported-syntax-guard: unsupported keyword '" .. token.value .. "' at " .. token.start)
        end
        if token.value == "function" and tokens[index + 1] and tokens[index + 1].value == "(" then
            error("unsupported-syntax-guard: anonymous functions are not supported at " .. token.start)
        end
    end
    local ok, parse_error = pcall(Parser.parse, source)
    if not ok then error("unsupported-syntax-guard: unsupported syntax: " .. tostring(parse_error)) end
    Step.last_metadata = { token_count = #tokens, parser_validated = true, validated = true }
    return source
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
