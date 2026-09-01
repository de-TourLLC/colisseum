local Lexer = require("src.core.lexer")

local Step = {}
Step.name = "strip-comments"
Step.version = 1

local function blank_comment(value)
    -- Keep line boundaries for diagnostics and to prevent line comments from
    -- swallowing the following statement.
    local blank = value:gsub("[^\r\n]", " ")
    if blank == "" then return " " end
    return blank
end

function Step.apply(source)
    if type(source) ~= "string" then
        error("strip-comments: source must be a string")
    end

    local output = {}
    local cursor = 1
    for _, token in ipairs(Lexer.scan(source)) do
        if token.kind == "comment" then
            output[#output + 1] = source:sub(cursor, token.start - 1)
            output[#output + 1] = blank_comment(token.value)
            cursor = token.finish + 1
        end
    end
    output[#output + 1] = source:sub(cursor)
    return table.concat(output)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
