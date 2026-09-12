local Lexer = require("src.core.lexer")
local Entropy = require("src.core.entropy")

local Step = {}
Step.name = "signature"
Step.version = 1
Step.emits_valid = true


local SAFE = 2 ^ 52
local function json_decode(text)
    local pos = 1

    local function skip_ws()
        local _, stop = text:find("^[ \t\r\n]+", pos)
        if stop then pos = stop + 1 end
    end

    local function parse_string()
        pos = pos + 1
        local parts = {}
        while true do
            local char = text:sub(pos, pos)
            if char == "" then error("signature: unterminated string in JSON") end
            if char == '"' then pos = pos + 1 break end
            if char == "\\" then
                local escape = text:sub(pos + 1, pos + 1)
                local map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
                if map[escape] then
                    parts[#parts + 1] = map[escape]
                    pos = pos + 2
                else
                    error("signature: bad escape in JSON")
                end
            else
                parts[#parts + 1] = char
                pos = pos + 1
            end
        end
        return table.concat(parts)
    end

    local function parse_value()
        skip_ws()
        local char = text:sub(pos, pos)
        if char == '"' then
            return parse_string()
        elseif char == "{" then
            local object = {}
            pos = pos + 1
            skip_ws()
            if text:sub(pos, pos) == "}" then pos = pos + 1 return object end
            while true do
                skip_ws()
                local key = parse_string()
                skip_ws()
                if text:sub(pos, pos) ~= ":" then error("signature: expected ':' in JSON") end
                pos = pos + 1
                object[key] = parse_value()
                skip_ws()
                local sep = text:sub(pos, pos)
                pos = pos + 1
                if sep == "}" then break end
                if sep ~= "," then error("signature: expected ',' or '}' in JSON") end
            end
            return object
        elseif char == "[" then
            local array = {}
            pos = pos + 1
            skip_ws()
            if text:sub(pos, pos) == "]" then pos = pos + 1 return array end
            while true do
                array[#array + 1] = parse_value()
                skip_ws()
                local sep = text:sub(pos, pos)
                pos = pos + 1
                if sep == "]" then break end
                if sep ~= "," then error("signature: expected ',' or ']' in JSON") end
            end
            return array
        elseif text:sub(pos, pos + 3) == "true" then pos = pos + 4 return true
        elseif text:sub(pos, pos + 4) == "false" then pos = pos + 5 return false
        elseif text:sub(pos, pos + 3) == "null" then pos = pos + 4 return nil
        else
            local number = text:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
            if not number or number == "" then error("signature: unexpected token in JSON") end
            pos = pos + #number
            return tonumber(number)
        end
    end

    return parse_value()
end

local pool_cache
local function load_pool()
    if pool_cache then return pool_cache end
    local candidates = { "src/steps/noise/signature.json" }
    local info = debug and debug.getinfo and debug.getinfo(1, "S")
    if info and info.source and info.source:sub(1, 1) == "@" then
        local dir = info.source:sub(2):match("^(.*[/\\])") or ""
        candidates[#candidates + 1] = dir .. "signature.json"
    end
    for _, path in ipairs(candidates) do
        local handle = io.open(path, "rb")
        if handle then
            local text = handle:read("*a")
            handle:close()
            local ok, decoded = pcall(json_decode, text)
            if ok and type(decoded) == "table" then
                pool_cache = decoded
                return pool_cache
            end
        end
    end
    error("signature: cannot load signature.json")
end

local function sanitize(text)
    text = tostring(text or "")
    text = text:gsub('["\\%z\r\n]', " ")
    text = text:gsub("%s+", " ")
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return text
end

local function disguise(prng, value, pool)
    local phrase = sanitize(prng:pick(pool.phrases))
    if phrase == "" then return nil end
    local length = #phrase
    local literal = '"' .. phrase .. '"'
    if value >= length and prng:float() < 0.5 then
        -- (#("phrase") + (value-length)) == value
        return "((#(" .. literal .. ")+" .. (value - length) .. "))"
    end
    -- ((value+length) - #("phrase")) == value
    return "((" .. (value + length) .. "-#(" .. literal .. ")))"
end

function Step.apply(source, options)
    if type(source) ~= "string" then error("signature: source must be a string") end
    if options ~= nil and type(options) ~= "table" then error("signature: options must be a table") end
    options = options or {}
    local prng = Entropy.prng(options.seed or "signature")
    local density = options.density or 0.35
    if type(density) ~= "number" or density < 0 or density > 1 then
        error("signature: density must be between 0 and 1")
    end
    local max_bytes = options.max_bytes or 131072
    if type(max_bytes) ~= "number" or max_bytes < 1 or max_bytes % 1 ~= 0 then
        error("signature: max_bytes must be a positive integer")
    end
    if max_bytes > 4 * 1024 * 1024 then error("signature: max_bytes exceeds the hard limit") end
    local pool = load_pool()

    local shebang = source:match("^(#![^\n]*\n)") or ""
    local body = source:sub(#shebang + 1)

    local out, cursor, budget = {}, 1, max_bytes
    for _, token in ipairs(Lexer.scan(body)) do
        out[#out + 1] = body:sub(cursor, token.start - 1)
        local text = body:sub(token.start, token.finish)
        local value = tonumber(token.value)
        local plain_integer = token.kind == "number" and value and value == math.floor(value)
            and math.abs(value) < SAFE and not token.value:find("[%.eExX]")
        if plain_integer and budget > 64 and prng:float() < density then
            local replacement = disguise(prng, value, pool)
            if replacement and (#replacement - #text) <= budget then
                out[#out + 1] = replacement
                budget = budget - (#replacement - #text)
            else
                out[#out + 1] = text
            end
        else
            out[#out + 1] = text
        end
        cursor = token.finish + 1
    end
    out[#out + 1] = body:sub(cursor)

    local credit = sanitize(pool.credit or "This file was obfuscated using Colisseum | WEBSITE SOON")
    local header = "local " .. prng:identifier(prng:range(6, 10)) .. '="' .. credit .. '";'

    Step.last_metadata = { budget_used = max_bytes - budget, validated = true }
    return shebang .. header .. table.concat(out)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
