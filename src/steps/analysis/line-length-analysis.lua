local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")

local Step = { name = "line-length-analysis", version = 1 }
Step.metadata = { id = Step.name, version = Step.version, kind = "validation", description = "Validates source and enforces a maximum physical line length." }

function Step.apply(source, options)
    if type(source) ~= "string" then error(Step.name .. ": source must be a string") end
    if options ~= nil and type(options) ~= "table" then error(Step.name .. ": options must be a table") end
    local valid, message, position = Validate.syntax(source)
    if not valid then error(Step.name .. ": " .. message .. " at " .. position) end
    local limit = (options or {}).max_length or 2000
    if type(limit) ~= "number" or limit < 1 or limit % 1 ~= 0 then error(Step.name .. ": max_length must be a positive integer") end
    local maximum, line = 0, 1
    for value in (source .. "\n"):gmatch("(.-)\n") do if #value > maximum then maximum = #value end; if #value > limit then error(Step.name .. ": line " .. line .. " exceeds maximum length") end; line = line + 1 end
    Step.last_metadata = { line_count = line - 1, maximum_line_length = maximum, token_count = #Lexer.scan(source), validated = true }
    return source
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
