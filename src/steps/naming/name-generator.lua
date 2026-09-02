local Generator = {}

local function mix(value)
    return (value * 1103515245 + 12345) % 2147483647
end

-- Produces confusable identifiers in the classic confusable style: a branded
-- prefix followed by characters drawn from a tiny, visually similar alphabet.
-- Defaults to `coli_` + 6-8 of {j, L}, matching the VM backends' colon prefix.
-- All of it is configurable per build.
function Generator.new(seed, config)
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
    local counter = 0
    local generator = {}

    local function build(length)
        local parts = {}
        for index = 1, length do
            state = mix(state)
            -- Use high-order bits; an LCG's low bits are strongly biased (which
            -- with a 2-char alphabet produced near-constant names).
            local position = math.floor(state / 65536) % nchars + 1
            parts[index] = charset:sub(position, position)
        end
        return prefix .. table.concat(parts)
    end

    function generator:next()
        local value
        -- Bounded random attempts; the alphabet is small, so an unbounded retry
        -- loop would hang once the reachable names of a given length are taken.
        for _ = 1, 8 do
            state = mix(state)
            value = build(min_len + math.floor(state / 256) % span)
            if not used[value] then break end
        end
        -- Guaranteed-unique, always-terminating fallback that stays in the same
        -- alphabet: encode a monotonic counter as charset "digits", padded longer
        -- than any random name so it can never collide with one.
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
