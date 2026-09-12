-- RFC 8439 ChaCha20 keystream generator, portable across Lua 5.1 / LuaJIT / Luau.
-- Used as the register VM's byte-stream cipher: the fogged program blob is XORed
-- with a ChaCha20 keystream (a real stream cipher) instead of an ad-hoc hash mask.
-- The keystream is derived once at VM start and applied on demand, so the decoded
-- program never materializes in memory.
--
-- All 32-bit operations are exact on IEEE doubles with no bit library required:
--   * add mod 2^32 : (a + b) % 2^32                      (sum < 2^33 < 2^53)
--   * rotate-left  : (x % 2^(32-n))*2^n + floor(x/2^(32-n))  (both parts < 2^32)
--   * xor          : native bit32/bit if present, else a portable arithmetic xor
-- so build-time (this module) and the inlined runtime copy agree byte-for-byte on
-- every host.

local ChaCha = {}

local floor = math.floor

-- 2^n table for n = 0..32.
local POW = {}
do
    local v = 1
    for i = 0, 32 do POW[i] = v; v = v * 2 end
end

-- 32-bit xor: native where available (fast + exact), portable arithmetic otherwise.
local xor32
do
    local b32 = bit32 or rawget(_G, "bit")
    if b32 and type(b32.bxor) == "function" then
        local bx = b32.bxor
        xor32 = function(a, b) return bx(a, b) % 4294967296 end
    else
        xor32 = function(a, b)
            local r, p = 0, 1
            while a > 0 or b > 0 do
                local ba, bb = a % 2, b % 2
                if ba ~= bb then r = r + p end
                a = floor(a / 2); b = floor(b / 2); p = p * 2
            end
            return r
        end
    end
end

local function add32(a, b) return (a + b) % 4294967296 end

local function rotl32(x, n)
    local lo = x % POW[32 - n]
    return lo * POW[n] + floor(x / POW[32 - n])
end

local function quarter(s, a, b, c, d)
    s[a] = add32(s[a], s[b]); s[d] = rotl32(xor32(s[d], s[a]), 16)
    s[c] = add32(s[c], s[d]); s[b] = rotl32(xor32(s[b], s[c]), 12)
    s[a] = add32(s[a], s[b]); s[d] = rotl32(xor32(s[d], s[a]), 8)
    s[c] = add32(s[c], s[d]); s[b] = rotl32(xor32(s[b], s[c]), 7)
end

-- One 64-byte ChaCha20 block. `key` is 8 words, `nonce` is 3 words, `counter` a
-- word. Returns 16 output words (little-endian bytes are emitted by keystream()).
local function block(key, counter, nonce)
    local s = {
        1634760805, 857760878, 2036477234, 1797285236,
        key[1], key[2], key[3], key[4], key[5], key[6], key[7], key[8],
        counter, nonce[1], nonce[2], nonce[3],
    }
    local w = {}
    for i = 1, 16 do w[i] = s[i] end
    for _ = 1, 10 do
        quarter(w, 1, 5, 9, 13); quarter(w, 2, 6, 10, 14)
        quarter(w, 3, 7, 11, 15); quarter(w, 4, 8, 12, 16)
        quarter(w, 1, 6, 11, 16); quarter(w, 2, 7, 12, 13)
        quarter(w, 3, 8, 9, 14); quarter(w, 4, 5, 10, 15)
    end
    for i = 1, 16 do w[i] = add32(w[i], s[i]) end
    return w
end
ChaCha.block = block

-- Build 8 key words + 3 nonce words + a start counter from a small byte array
-- (the per-build fog). Deterministic on both build and runtime sides.
function ChaCha.derive(fog)
    local nf = #fog
    -- Expand the fog into 44 bytes with a simple multiplicative PRNG (portable).
    local state = 2166136261
    for i = 1, nf do state = (state + fog[i] * 16777619) % 4294967296; state = (state * 48271) % 4294967296 end
    local bytes = {}
    for i = 1, 44 do
        state = (state * 1103515245 + 12345) % 4294967296
        bytes[i] = floor(state / 65536) % 256
    end
    local function word(o) return bytes[o] + bytes[o + 1] * 256 + bytes[o + 2] * 65536 + bytes[o + 3] * 16777216 end
    local key, nonce = {}, {}
    for i = 1, 8 do key[i] = word((i - 1) * 4 + 1) end
    for i = 1, 3 do nonce[i] = word(32 + (i - 1) * 4 + 1) end
    return key, nonce, 1
end

-- Generate `n` keystream bytes for (key, nonce, counter0).
function ChaCha.keystream(key, nonce, counter0, n)
    local out = {}
    local produced = 0
    local counter = counter0
    while produced < n do
        local w = block(key, counter, nonce)
        for i = 1, 16 do
            local v = w[i]
            local base = produced + (i - 1) * 4
            if base + 1 <= n then out[base + 1] = v % 256 end
            if base + 2 <= n then out[base + 2] = floor(v / 256) % 256 end
            if base + 3 <= n then out[base + 3] = floor(v / 65536) % 256 end
            if base + 4 <= n then out[base + 4] = floor(v / 16777216) % 256 end
        end
        produced = produced + 64
        counter = (counter + 1) % 4294967296
    end
    return out
end

return ChaCha
