local Entropy = require("src.core.entropy")

local Step = {}
Step.name = "strings"
Step.version = 2

-- LCG keystream constants, mirrored in the emitted decoder so literals round-trip.
local MASK_MULT, MASK_INC, MASK_MOD = 1103515245, 12345, 2147483648

-- No-seed fallback: the original deterministic string.char() construction.
local function encode_plain(value)
    local bytes = {}
    for index = 1, #value do bytes[index] = string.byte(value, index) end
    return "string.char(" .. table.concat(bytes, ",") .. ")"
end

-- Seeded: each literal gets its own keystream seed, so identical strings encode
-- to different byte arrays every build and no literal survives as a fixed value.
local function encode_keyed(value, prng, decoder)
    local literal_seed = prng:range(1, MASK_MOD - 1)
    local state, bytes = literal_seed, {}
    for index = 1, #value do
        state = (state * MASK_MULT + MASK_INC) % MASK_MOD
        local mask = math.floor(state / 65536) % 256
        bytes[index] = (value:byte(index) + mask) % 256
    end
    -- Parenthesised so it stays a valid expression even in call-sugar position.
    return "(" .. decoder .. "({" .. table.concat(bytes, ",") .. "}," .. literal_seed .. "))"
end

function Step.apply(source, options)
    if type(source) ~= "string" then error("strings: source must be a string") end
    if options ~= nil and type(options) ~= "table" then error("strings: options must be a table") end
    options = options or {}
    local prng = options.seed ~= nil and Entropy.prng(options.seed) or nil
    local shebang = source:match("^(#![^\n]*\n)") or ""
    local body = source:sub(#shebang + 1)
    local decoder
    if prng then
        repeat decoder = prng:identifier(prng:range(10, 16)) until not body:find(decoder, 1, true)
    end

    local output = {}
    local index = 1
    local used_decoder = false
    while index <= #body do
        local char = body:sub(index, index)
        if char == "-" and body:sub(index, index + 1) == "--" then
            local long = body:sub(index + 2, index + 3) == "[["
            local finish = long and (body:find("]]", index + 4, true) or #body - 1) or
                (body:find("\n", index + 2, true) or #body + 1)
            output[#output + 1] = body:sub(index, finish)
            index = finish + (long and 2 or 1)
        elseif char == "[" and body:sub(index, index + 1) == "[[" then
            local finish = body:find("]]", index + 2, true) or #body - 1
            output[#output + 1] = body:sub(index, finish + 1)
            index = finish + 2
        elseif char == "\"" or char == "'" then
            local quote = char
            local finish = index + 1
            local escaped = false
            while finish <= #body do
                local current = body:sub(finish, finish)
                if current == quote and not escaped then break end
                escaped = current == "\\" and not escaped
                if current ~= "\\" then escaped = false end
                finish = finish + 1
            end
            local value = body:sub(index + 1, finish - 1)
            if finish <= #body and not value:find("\\", 1, true) then
                if prng then
                    output[#output + 1] = encode_keyed(value, prng, decoder)
                    used_decoder = true
                else
                    output[#output + 1] = encode_plain(value)
                end
                index = finish + 1
            else
                output[#output + 1] = body:sub(index, math.min(finish, #body))
                index = math.min(finish + 1, #body + 1)
            end
        else
            output[#output + 1] = char
            index = index + 1
        end
    end

    local transformed = table.concat(output)
    local prelude = ""
    if used_decoder then
        prelude = "local " .. decoder .. "=function(t,s)local o={}for i=1,#t do s=(s*" .. MASK_MULT ..
            "+" .. MASK_INC .. ")%" .. MASK_MOD .. " o[i]=string.char((t[i]-math.floor(s/65536)%256)%256)end return table.concat(o)end\n"
    end
    return shebang .. prelude .. transformed
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
