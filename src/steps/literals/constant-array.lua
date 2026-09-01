local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")
local Entropy = require("src.core.entropy")

local Step = {}
Step.name = "constant-array"
Step.version = 1

-- Pools string literals into a single
-- shuffled, keyed-encoded array and replaces each occurrence with an indexed
-- lookup, so no literal appears in place and their order is scrambled. Native
-- token-level implementation; the shuffle is baked into the emitted indices so
-- there is no runtime un-shuffle cost.
local MASK_MULT, MASK_INC, MASK_MOD = 1103515245, 12345, 2147483648

local function encode_bytes(value, seed)
    local state, bytes = seed % MASK_MOD, {}
    for index = 1, #value do
        state = (state * MASK_MULT + MASK_INC) % MASK_MOD
        bytes[index] = (value:byte(index) + math.floor(state / 65536) % 256) % 256
    end
    return "{" .. table.concat(bytes, ",") .. "}"
end

-- Scan for quoted string literals with no escapes (safe to relocate verbatim),
-- skipping comments and long strings. Returns ordered occurrences.
local function collect_strings(body)
    local occurrences = {}
    local index, length = 1, #body
    while index <= length do
        local char = body:sub(index, index)
        if char == "-" and body:sub(index, index + 1) == "--" then
            local long = body:sub(index + 2, index + 3) == "[["
            local finish = long and (body:find("]]", index + 4, true) or length) or
                (body:find("\n", index + 2, true) or length + 1)
            index = finish + (long and 2 or 1)
        elseif char == "[" and body:sub(index, index + 1) == "[[" then
            local finish = body:find("]]", index + 2, true) or length - 1
            index = finish + 2
        elseif char == "\"" or char == "'" then
            local quote, finish, escaped = char, index + 1, false
            while finish <= length do
                local current = body:sub(finish, finish)
                if current == quote and not escaped then break end
                escaped = current == "\\" and not escaped
                if current ~= "\\" then escaped = false end
                finish = finish + 1
            end
            local value = body:sub(index + 1, finish - 1)
            if finish <= length and not value:find("\\", 1, true) then
                occurrences[#occurrences + 1] = { start = index, finish = finish, value = value }
            end
            index = finish + 1
        else
            index = index + 1
        end
    end
    return occurrences
end

function Step.apply(source, options)
    if type(source) ~= "string" then error("constant-array: source must be a string") end
    if options ~= nil and type(options) ~= "table" then error("constant-array: options must be a table") end
    options = options or {}
    local prng = Entropy.prng(options.seed or "constant-array")

    local shebang = source:match("^(#![^\n]*\n)") or ""
    local body = source:sub(#shebang + 1)
    local occurrences = collect_strings(body)
    if #occurrences == 0 then return source end

    -- Unique values in first-seen order.
    local values, logical_of = {}, {}
    for _, occ in ipairs(occurrences) do
        if not logical_of[occ.value] then
            values[#values + 1] = occ.value
            logical_of[occ.value] = #values
        end
    end

    -- Shuffle: perm[physical] = logical index; inverse maps logical -> physical.
    local perm = {}
    for i = 1, #values do perm[i] = i end
    for i = #perm, 2, -1 do local j = prng:range(1, i); perm[i], perm[j] = perm[j], perm[i] end
    local physical_of = {}
    for physical, logical in ipairs(perm) do physical_of[logical] = physical end

    -- Encode each value (keyed, per-entry seed) at its physical position.
    local entries, seeds = {}, {}
    for physical, logical in ipairs(perm) do
        local seed = prng:range(1, MASK_MOD - 1)
        seeds[physical] = tostring(seed)
        entries[physical] = encode_bytes(values[logical], seed)
    end

    -- Holder names that do not appear in the body (rename will further mangle them).
    local function fresh()
        local name
        repeat name = prng:identifier(prng:range(8, 14)) until not body:find(name, 1, true)
        return name
    end
    local pool, key = fresh(), fresh()

    local prelude = "local " .. pool .. "={" .. table.concat(entries, ",") .. "}\n" ..
        "local " .. key .. "={" .. table.concat(seeds, ",") .. "}\n" ..
        "for _k=1,#" .. pool .. " do local _t=" .. pool .. "[_k] local _x=" .. key .. "[_k] local _b={} " ..
        "for _j=1,#_t do _x=(_x*" .. MASK_MULT .. "+" .. MASK_INC .. ")%" .. MASK_MOD ..
        " _b[_j]=string.char((_t[_j]-math.floor(_x/65536)%256)%256) end " ..
        pool .. "[_k]=table.concat(_b) end\n"

    -- Rebuild body, replacing each occurrence with a parenthesised indexed lookup
    -- (parens keep it valid even in call-sugar position: f"x" -> f((P[i]))).
    local out, cursor = {}, 1
    for _, occ in ipairs(occurrences) do
        out[#out + 1] = body:sub(cursor, occ.start - 1)
        out[#out + 1] = "(" .. pool .. "[" .. physical_of[logical_of[occ.value]] .. "])"
        cursor = occ.finish + 1
    end
    out[#out + 1] = body:sub(cursor)

    local result = shebang .. prelude .. table.concat(out)
    local valid, message, position = Validate.syntax(result)
    if not valid then error("constant-array: generated source is invalid at " .. tostring(position) .. ": " .. tostring(message)) end
    Step.last_metadata = { pooled = #values, occurrences = #occurrences, validated = true }
    return result
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
