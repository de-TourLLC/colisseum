-- Per-run entropy and a small deterministic PRNG.
--
-- Two goals, satisfied by one module:
--   * Every build is different. Entropy.collect() gathers real run-to-run
--     variation (wall clock, CPU clock, fresh heap/function addresses under
--     ASLR, and a process-monotonic counter) so no two obfuscations share the
--     same seeds, keys, names, or injected values -- even for identical input.
--   * Builds stay reproducible on demand. Given an explicit numeric seed the
--     PRNG replays exactly, so callers who *want* a stable build can ask for one.
--
-- The PRNG is MINSTD (Lehmer), pure integer arithmetic: no bit library, works
-- on Lua 5.1-5.4, LuaJIT, and Luau alike.

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

-- A fresh strong seed for this build. Mixes several independent entropy
-- sources so identical input never yields identical output, and the counter
-- guarantees two calls in the same clock tick still diverge.
function Entropy.collect()
    counter = counter + 1
    local material = table.concat({
        tostring(os.time()),
        tostring(os.clock()),
        tostring({}),          -- heap address; varies per run (ASLR) and per call
        tostring(Entropy),     -- table address, another ASLR source
        tostring(counter)
    }, "|")
    return fold(material)
end

-- Derive an independent sub-seed for a labelled consumer from a base seed, so
-- distinct steps in one build never share a keystream.
function Entropy.mix(base, label)
    local state = Entropy.normalize(base) or Entropy.collect()
    return fold(tostring(label), state)
end

local Prng = {}
Prng.__index = Prng

-- Build a PRNG. With a seed it is deterministic; without one it draws a fresh
-- seed from Entropy.collect() so each instance is unique.
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

-- A random Lua-safe identifier. Always leads with "_" then a letter, so it can
-- never collide with a reserved word and is always a valid identifier.
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
