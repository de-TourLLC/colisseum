-- numeric-fibonacci: replaces bounded decimal-integer literals with indexed reads
-- from a pooled table whose values are decoded ONCE at load from Zeckendorf
-- (Fibonacci-coding) codewords. A plaintext constant like 1337 becomes `_K[3]`,
-- and `_K` is filled at chunk start by a tiny injected decoder. Semantics-preserving
-- (every codeword is self-checked at build time to decode back to its exact value)
-- and Luau/Roblox-safe: the decoder is pure integer math over string bytes -- no
-- bitops, no loadstring -- and, crucially, it runs once at load, so hot loops pay a
-- table lookup, not a re-decode. Values are deduplicated; bounded; per-build named.

local Lexer = require("src.core.lexer")
local Validate = require("src.core.validate")
local Entropy = require("src.core.entropy")
local Fibonacci = require("src.core.fibonacci")

local Step = { name = "numeric-fibonacci", version = 1 }
Step.metadata = {
    id = Step.name,
    version = Step.version,
    kind = "transformation",
    description = "Rewrites bounded integer literals as indexed reads from a Fibonacci/Zeckendorf-decoded pool built once at load."
}

-- Largest integer we encode. The decoder builds the coding sequence to an index
-- that comfortably exceeds this, so every accepted value round-trips.
local MAX_VALUE = 2147483647

local function positive(options, name, default)
    local value = tonumber(options[name])
    if value == nil or value < 1 or value % 1 ~= 0 then return default end
    return math.floor(value)
end

function Step.apply(source, options)
    if type(source) ~= "string" then error(Step.name .. ": source must be a string") end
    if options ~= nil and type(options) ~= "table" then error(Step.name .. ": options must be a table") end
    options = options or {}
    if #source > 8 * 1024 * 1024 then error(Step.name .. ": source exceeds the 8388608 byte limit") end

    local min_value = positive(options, "min_value", 3)
    local max_replacements = positive(options, "max_replacements", 512)
    if max_replacements > 16384 then error(Step.name .. ": max_replacements exceeds the hard limit") end

    local prng = Entropy.prng(options.seed ~= nil and options.seed or "numeric-fibonacci")

    local shebang = source:match("^(#![^\n]*\n)") or ""
    local body = source:sub(#shebang + 1)

    local tokens = Lexer.scan(body)
    -- Qualifying integer literals, left-to-right. Only pure decimal integers in range
    -- (never hex/float/exponent tokens -- they carry '.', 'x', or 'e').
    local hits = {}
    for _, token in ipairs(tokens) do
        if token.kind == "number" and token.value:match("^%d+$") then
            local n = tonumber(token.value)
            if n and n >= min_value and n <= MAX_VALUE and n % 1 == 0 then
                hits[#hits + 1] = token
            end
        end
    end
    if #hits == 0 then return source end

    -- Deduplicate values into a pool; each distinct value gets one index. A codeword
    -- that fails to round-trip is dropped (its literals are left untouched).
    local index_of, pool_bits, pool_size = {}, {}, 0
    local function pool_index(value)
        if index_of[value] then return index_of[value] end
        local bits = Fibonacci.encode(value)
        if Fibonacci.decode(bits, 1) ~= value then return nil end
        pool_size = pool_size + 1
        index_of[value] = pool_size
        pool_bits[pool_size] = bits
        return pool_size
    end

    -- Splice from the highest offset down so earlier coordinates stay valid.
    local replaced = 0
    local prefix = "_" .. prng:identifier(prng:range(3, 5)):gsub("[^%w]", "")
    local pool_name = prefix .. "K"
    for i = #hits, 1, -1 do
        if replaced >= max_replacements then break end
        local token = hits[i]
        local idx = pool_index(tonumber(token.value))
        if idx then
            body = body:sub(1, token.start - 1) .. pool_name .. "[" .. idx .. "]" .. body:sub(token.finish + 1)
            replaced = replaced + 1
        end
    end
    if replaced == 0 then return source end

    -- Pool initializer: build the coding sequence 1,2,3,5,8,... once, then decode
    -- each codeword into _K[i]. `_d` sums the Fibonacci numbers whose usage bit is
    -- set, stopping at the "11" terminator (byte 49 is '1'). All local to a `do`
    -- block, so only _K escapes.
    local fib_name = prefix .. "f"
    local dec_name = prefix .. "d"
    local init = {}
    init[#init + 1] = "local " .. pool_name .. "={} do "
    init[#init + 1] = "local " .. fib_name .. "={1,2} for _k=3,50 do " .. fib_name ..
        "[_k]=" .. fib_name .. "[_k-1]+" .. fib_name .. "[_k-2] end "
    init[#init + 1] = "local " .. dec_name .. "=function(_b) local _n,_i,_p=0,1,0 for _j=1,#_b do " ..
        "local _c=_b:byte(_j) if _c==49 and _p==49 then return _n end " ..
        "if _c==49 then _n=_n+" .. fib_name .. "[_i] end _p=_c _i=_i+1 end return _n end "
    for i = 1, pool_size do
        init[#init + 1] = pool_name .. "[" .. i .. "]=" .. dec_name .. '("' .. pool_bits[i] .. '") '
    end
    init[#init + 1] = "end\n"

    local result = shebang .. table.concat(init) .. body
    local valid = Validate.syntax(result)
    if not valid then
        -- Any unexpected splice context: ship the original untouched rather than
        -- emit something that will not load.
        return source
    end
    Step.last_metadata = { replaced = replaced, pool = pool_size, candidates = #hits }
    return result
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
