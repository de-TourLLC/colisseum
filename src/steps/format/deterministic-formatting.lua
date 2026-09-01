local Lexer = require("src.core.lexer")

local Step = { name = "deterministic-formatting", version = 1 }

local function boundary(left, right)
    if not left or not right or left.kind == "comment" or right.kind == "comment" then return false end
    local joined = Lexer.scan(left.value .. right.value)
    return #joined ~= 2 or joined[1].value ~= left.value or joined[2].value ~= right.value
end

local function format_gap(value)
    value = value:gsub("\r\n", "\n"):gsub("\r", "\n")
    return value:find("\n", 1, true) and value:gsub("[ \t]+", "") or ""
end

function Step.apply(source)
    if type(source) ~= "string" then error(Step.name .. ": source must be a string") end
    local output, cursor, previous = {}, 1, nil
    for _, token in ipairs(Lexer.scan(source)) do
        local gap = source:sub(cursor, token.start - 1)
        if gap:find("\n", 1, true) then
            gap = format_gap(gap)
        elseif boundary(previous, token) then
            gap = " "
        else
            gap = ""
        end
        output[#output + 1] = gap
        output[#output + 1] = token.value
        previous, cursor = token, token.finish + 1
    end
    output[#output + 1] = format_gap(source:sub(cursor))
    return table.concat(output)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
