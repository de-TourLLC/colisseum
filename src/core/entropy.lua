-- Per-run entropy plus a deterministic PRNG (MINSTD/Lehmer).
-- collect() varies every build; an explicit seed replays exactly.

local Entropy = {}

local MODULUS = 2147483647 -- 2^31 - 1, a Mersenne prime; MINSTD's modulus.
local MULTIPLIER = 48271
local counter = 0

-- FNV-1a-flavoured fold of a string into [1, MODULUS).
local function fold(value, state)
    state = state or 2166136261
    for index = 1, #value do
        state = (state + value:byte(index) * 16777619) % MODULUS
        state = (state * MULTIPLIER) % MODULUS
    end
    if state == 0 then state = 2654435761 % MODULUS end
    return state
end

Entropy.fold = fold

-- Coerce any caller-supplied seed (number, string, nil) into a PRNG state.
function Entropy.normalize(seed)
    if seed == nil then return nil end
    local numeric = tonumber(seed)
    if numeric then
        numeric = math.floor(numeric) % MODULUS
        return numeric == 0 and 1 or numeric
    end
    return fold(tostring(seed))
end

-- Fresh per-build seed: a wide string of two 31-bit folds (~62 bits). The counter
-- keeps two calls in the same clock tick from colliding.
function Entropy.collect()
    counter = counter + 1
    local material = table.concat({
        tostring(os.time()),
        tostring(os.clock()),
        tostring({}),          -- heap address; varies per run (ASLR) and per call
        tostring(Entropy),     -- table address, another ASLR source
        tostring(counter)
    }, "|")
    -- Fold the material from two starting states and join for wider entropy.
    local a = fold(material, 2166136261)
    local b = fold(material, 2654435761)
    return tostring(a) .. ":" .. tostring(b)
end

-- Derive an independent sub-seed for a labelled consumer, so steps never share a keystream.
function Entropy.mix(base, label)
    local state = Entropy.normalize(base) or Entropy.collect()
    return fold(tostring(label), state)
end

local Prng = {}
Prng.__index = Prng

-- Build a PRNG: deterministic with a seed, otherwise seeded from Entropy.collect().
function Entropy.prng(seed)
    local state = Entropy.normalize(seed) or Entropy.collect()
    return setmetatable({ state = state }, Prng)
end

function Prng:next()
    self.state = (self.state * MULTIPLIER) % MODULUS
    return self.state
end

function Prng:float()
    return self:next() / MODULUS
end

-- Inclusive integer in [low, high].
function Prng:range(low, high)
    if high < low then low, high = high, low end
    return low + (self:next() % (high - low + 1))
end

function Prng:pick(list)
    return list[self:range(1, #list)]
end

local ALPHA = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
local ALNUM = ALPHA .. "0123456789"

-- Random Lua-safe identifier. Leads with "_" then a letter, so it never hits a reserved word.
function Prng:identifier(length)
    length = length or self:range(6, 12)
    local head = self:range(1, #ALPHA)
    local chars = { "_", ALPHA:sub(head, head) }
    for index = 3, length do
        local pick = self:range(1, #ALNUM)
        chars[index] = ALNUM:sub(pick, pick)
    end
    return table.concat(chars)
end

return Entropy
