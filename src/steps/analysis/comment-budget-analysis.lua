local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")

local Step = { name = "comment-budget-analysis", version = 1 }
Step.metadata = { id = Step.name, version = Step.version, kind = "validation", description = "Bounds comment count and comment bytes without altering source." }

function Step.apply(source, options)
    if type(source) ~= "string" then error(Step.name .. ": source must be a string") end
    if options ~= nil and type(options) ~= "table" then error(Step.name .. ": options must be a table") end
    local valid, message, position = Validate.syntax(source)
    if not valid then error(Step.name .. ": " .. message .. " at " .. position) end
    options = options or {}; local count_limit, byte_limit = options.max_comments or 1000, options.max_comment_bytes or 100000
    if type(count_limit) ~= "number" or count_limit < 1 or count_limit % 1 ~= 0 or type(byte_limit) ~= "number" or byte_limit < 1 or byte_limit % 1 ~= 0 then error(Step.name .. ": comment budgets must be positive integers") end
    local count, bytes = 0, 0
    for _, token in ipairs(Lexer.scan(source)) do if token.kind == "comment" then count = count + 1; bytes = bytes + #token.value end end
    if count > count_limit then error(Step.name .. ": comment count budget exceeded") end
    if bytes > byte_limit then error(Step.name .. ": comment byte budget exceeded") end
    Step.last_metadata = { comment_count = count, comment_bytes = bytes, validated = true }
    return source
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
