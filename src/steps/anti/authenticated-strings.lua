local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")

local Step = {
    name = "authenticated-strings",
    version = 1,
    metadata = {
        description = "Adds bounded per-build integrity checks to quoted string literals.",
        limitation = "The default tag is not cryptographic authenticity: its key and metadata are emitted with the program. Use a host verifier hook for an external trust decision."
    }
}

local build_number = 0
local MAX_SOURCE = 4 * 1024 * 1024
local MAX_STRING = 64 * 1024
local MAX_OUTPUT = 8 * 1024 * 1024

local function hash(value, seed)
    local state = (seed or 2166136261) % 2147483647
    for index = 1, #value do
        state = (state + value:byte(index) * 16777619) % 2147483647
        state = (state * 48271) % 2147483647
    end
    return state
end

local escapes = { a = 7, b = 8, f = 12, n = 10, r = 13, t = 9, v = 11,
    ["\\"] = 92, ["\""] = 34, ["'"] = 39 }

local function decode_quoted(token)
    local result, index, finish = {}, 2, #token - 1
    while index <= finish do
        local char = token:sub(index, index)
        if char ~= "\\" then
            result[#result + 1] = char
            index = index + 1
        else
            index = index + 1
            if index > finish then return nil end
            char = token:sub(index, index)
            local value = escapes[char]
            if value then
                result[#result + 1] = string.char(value)
                index = index + 1
            elseif char == "z" then
                index = index + 1
                while index <= finish and token:sub(index, index):match("%s") do index = index + 1 end
            elseif char == "x" and token:sub(index + 1, index + 2):match("^[%da-fA-F][%da-fA-F]$") then
                result[#result + 1] = string.char(tonumber(token:sub(index + 1, index + 2), 16))
                index = index + 3
            elseif char:match("%d") then
                local digits = token:sub(index):match("^%d%d?%d?")
                local number = tonumber(digits)
                if not number or number > 255 then return nil end
                result[#result + 1] = string.char(number)
                index = index + #digits
            elseif char == "\n" then
                result[#result + 1] = "\n"
                index = index + 1
            elseif char == "\r" then
                result[#result + 1] = "\n"
                index = index + 1
                if token:sub(index, index) == "\n" then index = index + 1 end
            else
                return nil
            end
        end
    end
    return table.concat(result)
end

local function number_option(options, name, default, maximum)
    local value = options[name]
    if value == nil then return default end
    value = tonumber(value)
    if not value or value < 1 or value % 1 ~= 0 or value > maximum then
        error("authenticated-strings: " .. name .. " is out of range")
    end
    return value
end

local function replacement(token, key, index, hook)
    local value = decode_quoted(token.value)
    if not value or #value > 64 * 1024 then return token.value, false end
    local tag = hash(value, key)
    local hook_name = string.format("%q", hook or "")
    local expression = ([=[(function(_as_v,_as_t,_as_k,_as_hook,_as_g)
    local _as_f = rawget(_as_g, _as_hook)
    if type(_as_f) == "function" then
        local _as_ok, _as_result = pcall(_as_f, _as_v, _as_t, %d)
        if not _as_ok or _as_result ~= true then error("authenticated-strings: host verification failed", 0) end
    else
        local _as_h = _as_k %% 2147483647
        for _as_i = 1, #_as_v do
            _as_h = (_as_h + _as_v:byte(_as_i) * 16777619) %% 2147483647
            _as_h = (_as_h * 48271) %% 2147483647
        end
        if _as_h ~= _as_t then error("authenticated-strings: integrity check failed", 0) end
    end
    return _as_v
    end)(%s,%d,%d,%s,_G)]=]):format(index, token.value, tag, key, hook_name)
    return expression, true
end

function Step.apply(source, options)
    if type(source) ~= "string" then error("authenticated-strings: source must be a string") end
    options = options or {}
    if type(options) ~= "table" then error("authenticated-strings: options must be a table") end
    if #source > MAX_SOURCE then error("authenticated-strings: source exceeds maximum size") end

    local max_string = number_option(options, "maxPayloadBytes", MAX_STRING, MAX_STRING)
    local max_output = number_option(options, "maxBytes", MAX_OUTPUT, MAX_OUTPUT)
    local hook = options.hostVerifier
    if hook ~= nil and (type(hook) ~= "string" or not hook:match("^[%a_][%w_]*$")) then
        error("authenticated-strings: hostVerifier must be a global identifier")
    end

    build_number = build_number + 1
    local key = hash(source .. tostring(options.seed or "") .. tostring(build_number), 173)
    local output, cursor, transformed = {}, 1, 0
    for index, token in ipairs(Lexer.scan(source)) do
        output[#output + 1] = source:sub(cursor, token.start - 1)
        if token.kind == "string" and token.value:sub(1, 1) ~= "[" then
            local value = decode_quoted(token.value)
            if value and #value > max_string then
                error("authenticated-strings: string literal exceeds maxPayloadBytes")
            elseif value then
                output[#output + 1] = replacement(token, key, index, hook)
                transformed = transformed + 1
            else
                output[#output + 1] = token.value
            end
        else
            output[#output + 1] = token.value
        end
        cursor = token.finish + 1
    end
    output[#output + 1] = source:sub(cursor)
    local result = table.concat(output)
    if #result > max_output then error("authenticated-strings: output exceeds maxBytes") end
    local valid, message = Validate.syntax(result)
    if not valid then error("authenticated-strings: generated output is invalid: " .. tostring(message)) end
    Step.last_metadata = {
        transformed = transformed,
        key = key,
        validated = true,
        limitation = Step.metadata.limitation,
        host_verifier = hook
    }
    return result
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
