local Lexer = require("src.core.lexer")
local byte = string.byte

local Step = { name = "string-byte-encoding", version = 1 }

local simple_escapes = { a = 7, b = 8, f = 12, n = 10, r = 13, t = 9, v = 11, ["\\"] = 92, ["\""] = 34, ["'"] = 39 }

local function decode(value)
    local bytes, index = {}, 2
    local finish = #value - 1
    while index <= finish do
        local char = value:sub(index, index)
        if char ~= "\\" then
            bytes[#bytes + 1] = byte(char)
            index = index + 1
        else
            index = index + 1
            if index > finish then return nil end
            char = value:sub(index, index)
            local escaped = simple_escapes[char]
            if escaped then
                bytes[#bytes + 1] = escaped
                index = index + 1
            elseif char == "z" then
                index = index + 1
                while index <= finish and value:sub(index, index):match("%s") do index = index + 1 end
            elseif char:match("%d") then
                local digits = value:sub(index):match("^%d%d?%d?")
                local number = tonumber(digits)
                if not number or number > 255 then return nil end
                bytes[#bytes + 1] = number
                index = index + #digits
            elseif char == "x" and value:sub(index + 1, index + 2):match("^[%da-fA-F][%da-fA-F]$") then
                bytes[#bytes + 1] = tonumber(value:sub(index + 1, index + 2), 16)
                index = index + 3
            elseif char == "\n" then
                bytes[#bytes + 1] = 10
                index = index + 1
            elseif char == "\r" then
                bytes[#bytes + 1] = 13
                index = index + 1
                if value:sub(index, index) == "\n" then index = index + 1 end
            else
                return nil
            end
        end
    end
    return bytes
end

local function replacement(value)
    if value:sub(1, 1) == "[" then return nil end
    local bytes = decode(value)
    if not bytes then return nil end
    return "(function(decoder) return decoder(" .. table.concat(bytes, ",") .. ") end)(string.char)"
end

function Step.apply(source)
    if type(source) ~= "string" then error("string-byte-encoding: source must be a string") end
    local output, cursor = {}, 1
    for _, token in ipairs(Lexer.scan(source)) do
        output[#output + 1] = source:sub(cursor, token.start - 1)
        output[#output + 1] = token.kind == "string" and replacement(token.value) or nil
            or token.value
        cursor = token.finish + 1
    end
    output[#output + 1] = source:sub(cursor)
    return table.concat(output)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
