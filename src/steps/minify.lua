local Lexer = require("src.core.lexer")

local Step = {}
Step.name = "minify"
Step.version = 2

function Step.apply(source)
    if type(source) ~= "string" then error("minify: source must be a string") end
    local output = {}
    local previous
    for _, token in ipairs(Lexer.scan(source)) do
        if token.kind ~= "comment" then
            local needs_space = previous and
                (previous.kind == "identifier" or previous.kind == "number") and
                (token.kind == "identifier" or token.kind == "number")
            if needs_space then output[#output + 1] = " " end
            output[#output + 1] = token.value
            previous = token
        end
    end
    return table.concat(output)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
