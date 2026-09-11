-- Fibonacci (Zeckendorf) coding of positive integers, and a self-delimiting byte
-- codec built on it. This is the scheme in the reference image: greedily subtract
-- the largest Fibonacci number <= n, record which Fibonaccis were used as usage
-- bits ordered smallest -> largest, then append a terminal '1'.
--
--   n = 143  ->  used {2,5,13,34,89}  ->  usage bits 0101010101  ->  "01010101011"
--
-- The coding sequence is 1,2,3,5,8,13,21,34,55,89,144,... (the Fibonacci numbers
-- with the leading duplicate 1 dropped). Zeckendorf's theorem guarantees the greedy
-- decomposition never uses two consecutive Fibonaccis, so the usage bits contain no
-- "11"; the appended terminal '1' therefore always produces the FIRST "11" in the
-- stream exactly at the codeword boundary, making each codeword self-delimiting.
--
-- Pure integer arithmetic (no bitops, no floats): identical on Lua 5.1 / 5.3 /
-- LuaJIT / Luau, so anything encoded at build time decodes byte-for-byte at runtime.

local Fibonacci = {}

-- Extend `fibs` (the coding sequence) in place until its last value >= limit.
local function grow(fibs, limit)
    local m = #fibs
    if m == 0 then fibs[1] = 1; fibs[2] = 2; m = 2 end
    while fibs[m] < limit do
        fibs[m + 1] = fibs[m] + fibs[m - 1]
        m = m + 1
    end
    return fibs
end

-- Shared, lazily grown coding sequence.
local SEQ = { 1, 2 }

-- Encode one integer n >= 1 as a Fibonacci codeword (a string of '0'/'1' ending in
-- "11"). Errors on n < 1 or non-integers -- callers that need to carry 0 bias by +1.
function Fibonacci.encode(n)
    if type(n) ~= "number" or n < 1 or n % 1 ~= 0 then
        error("fibonacci: encode expects a positive integer, got " .. tostring(n))
    end
    grow(SEQ, n)
    -- Largest index k with SEQ[k] <= n.
    local k = #SEQ
    while SEQ[k] > n do k = k - 1 end
    local bits = {}
    for i = 1, k do bits[i] = "0" end
    local remaining = n
    for i = k, 1, -1 do
        if SEQ[i] <= remaining then
            bits[i] = "1"
            remaining = remaining - SEQ[i]
        end
    end
    return table.concat(bits) .. "1"
end

-- Decode one codeword from `bits` (a '0'/'1' string) starting at 1-based `start`.
-- Returns (value, next_position). `next_position` is one past the terminal '1'.
function Fibonacci.decode(bits, start)
    start = start or 1
    grow(SEQ, 1)
    local n, i, prev = 0, 1, "0"
    local pos = start
    local len = #bits
    while pos <= len do
        local b = bits:sub(pos, pos)
        if b == "1" and prev == "1" then
            -- Second half of the "11" terminator: the previous '1' was the last real
            -- usage bit (already counted); this '1' is the appended terminal.
            return n, pos + 1
        end
        if b == "1" then
            if i > #SEQ then grow(SEQ, SEQ[#SEQ] + 1) end
            n = n + SEQ[i]
        end
        prev = b
        i = i + 1
        pos = pos + 1
    end
    error("fibonacci: truncated codeword (no '11' terminator) from position " .. tostring(start))
end

-- Encode a byte string into one contiguous bit string. Each byte b (0..255) is
-- carried as the integer b+1 (so 0 is representable), concatenated as codewords.
-- Because every codeword self-delimits, no length prefixes are needed between them.
function Fibonacci.encode_bytes(data)
    if type(data) ~= "string" then error("fibonacci: encode_bytes expects a string") end
    local out = {}
    for i = 1, #data do
        out[i] = Fibonacci.encode(data:byte(i) + 1)
    end
    return table.concat(out)
end

-- Decode `count` bytes from a bit string produced by encode_bytes.
function Fibonacci.decode_bytes(bits, count)
    local out = {}
    local pos = 1
    for i = 1, count do
        local value, nextpos = Fibonacci.decode(bits, pos)
        out[i] = string.char((value - 1) % 256)
        pos = nextpos
    end
    return table.concat(out)
end

-- Pack a '0'/'1' bit string into a byte string (8 bits per byte, MSB first, the
-- final byte zero-padded on the right). Returns (packed, bit_length) so the exact
-- bit count -- and thus the padding -- is recoverable.
function Fibonacci.pack_bits(bits)
    local out = {}
    local n = #bits
    for i = 1, n, 8 do
        local byte = 0
        for j = 0, 7 do
            byte = byte * 2
            if bits:sub(i + j, i + j) == "1" then byte = byte + 1 end
        end
        out[#out + 1] = string.char(byte)
    end
    return table.concat(out), n
end

-- Inverse of pack_bits: unpack `bit_length` bits from a packed byte string.
function Fibonacci.unpack_bits(packed, bit_length)
    local out = {}
    for i = 1, bit_length do
        local byte_index = math.floor((i - 1) / 8) + 1
        local bit_index = 7 - ((i - 1) % 8)
        local byte = packed:byte(byte_index) or 0
        out[i] = (math.floor(byte / (2 ^ bit_index)) % 2 == 1) and "1" or "0"
    end
    return table.concat(out)
end

return Fibonacci
