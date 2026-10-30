local Generator = {}

local function mix(value)
    return (value * 1103515245 + 12345) % 2147483647
end

-- Confusable identifiers: a branded prefix plus chars from a tiny lookalike alphabet. Defaults to coli_ + 6-8 of {j,L}, all configurable.
--[[ `reserved` is an optional set of identifiers already in the source; marking them
     used keeps a generated name from colliding with an existing one (a global, an
     injected helper, a binding a re-rename pass left alone) and aliasing two variables. ]]
function Generator.new(seed, config, reserved)
    config = config or {}
    local prefix = config.prefix or "coli_"
    local charset = config.charset or "jL"
    local min_len = config.min_length or 6
    local max_len = config.max_length or 8
    if min_len < 1 or max_len < min_len then error("name-generator: invalid length range") end
    if #charset < 1 then error("name-generator: charset must be non-empty") end
    local span = max_len - min_len + 1
    local nchars = #charset
    local state = tonumber(seed) or os.time()
    local used = {}
    if reserved ~= nil then
        if type(reserved) ~= "table" then error("name-generator: reserved must be a table") end
        for name in pairs(reserved) do used[name] = true end
    end
    local counter = 0
    local generator = {}

    local function build(length)
        local parts = {}
        for index = 1, length do
            state = mix(state)
            -- high-order bits: an LCG's low bits are biased (near-constant names with a 2-char alphabet)
            local position = math.floor(state / 65536) % nchars + 1
            parts[index] = charset:sub(position, position)
        end
        return prefix .. table.concat(parts)
    end

    function generator:next()
        local value
        -- bounded attempts: the alphabet is small, so an unbounded retry could hang
        for _ = 1, 8 do
            state = mix(state)
            value = build(min_len + math.floor(state / 256) % span)
            if not used[value] then break end
        end
        -- Unique fallback: encode a monotonic counter as charset digits, padded longer than any random name so it can't collide.
        while used[value] do
            counter = counter + 1
            local n, parts = counter, {}
            repeat
                parts[#parts + 1] = charset:sub(n % nchars + 1, n % nchars + 1)
                n = math.floor(n / nchars)
            until n == 0
            while #parts <= max_len do parts[#parts + 1] = charset:sub(1, 1) end
            value = prefix .. table.concat(parts)
        end
        used[value] = true
        return value
    end

    return generator
end

return Generator
