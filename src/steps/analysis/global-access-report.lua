local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")
local Parser = require("src.core.parser")
local References = require("src.core.references")

local Step = { name = "global-access-report", version = 1 }
Step.metadata = { id = Step.name, version = Step.version, kind = "analysis", description = "Reports identifier reads that are not locally declared in the source." }
function Step.apply(source)
    if type(source) ~= "string" then error(Step.name .. ": source must be a string") end
    local valid, message, position = Validate.syntax(source)
    if not valid then error(Step.name .. ": " .. message .. " at " .. position) end
    local tokens, globals = Lexer.scan(source), {}
    local ok, ast = pcall(Parser.parse, source)
    if not ok then error(Step.name .. ": unable to analyze parsed source: " .. tostring(ast)) end
    local references = References.analyze(ast)
    for _, node in ipairs(references.unresolved) do globals[node.value] = true end
    local names = {}; for name in pairs(globals) do names[#names + 1] = name end; table.sort(names)
    Step.last_metadata = { global_count = #names, globals = names, validated = true }
    return source
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
