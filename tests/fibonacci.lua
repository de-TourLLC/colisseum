-- Regression tests for the Fibonacci (Zeckendorf) codec.
local function project_root()
    local source = debug.getinfo(1, "S").source:sub(2)
    return source:match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."
end
local root = project_root()
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local Fib = require("src.core.fibonacci")

local passed, failed = 0, 0
local function check(cond, msg)
    if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: " .. tostring(msg) .. "\n") end
end
local function eq(a, b, msg) check(a == b, (msg or "") .. " (expected " .. tostring(b) .. ", got " .. tostring(a) .. ")") end

-- 1. The exact worked example from the reference image.
eq(Fib.encode(143), "01010101011", "encode(143)")
local v, nextpos = Fib.decode("01010101011", 1)
eq(v, 143, "decode(codeword(143))")
eq(nextpos, 12, "decode advances past terminator")

-- 2. Small integers and their known Fibonacci codewords.
eq(Fib.encode(1), "11", "encode(1)")
eq(Fib.encode(2), "011", "encode(2)")
eq(Fib.encode(3), "0011", "encode(3)")
eq(Fib.encode(4), "1011", "encode(4)")
eq(Fib.encode(5), "00011", "encode(5)")
eq(Fib.encode(6), "10011", "encode(6)")
eq(Fib.encode(7), "01011", "encode(7)")

-- 3. Every codeword ends in "11" and contains no other "11" (self-delimiting).
for n = 1, 5000 do
    local code = Fib.encode(n)
    check(code:sub(-2) == "11", "codeword " .. n .. " ends in 11")
    check(code:sub(1, -2):find("11") == nil, "codeword " .. n .. " has no internal 11")
end

-- 4. Round-trip encode/decode over a wide integer range.
for n = 1, 20000 do
    local decoded = Fib.decode(Fib.encode(n), 1)
    if decoded ~= n then check(false, "round-trip integer " .. n); break end
end
check(true, "integer round-trip 1..20000")

-- 5. Byte-stream round-trip, including every byte value 0..255.
local all = {}
for b = 0, 255 do all[#all + 1] = string.char(b) end
local blob = table.concat(all) .. "\0\255\0\1\2coliseum\r\n"
local bits = Fib.encode_bytes(blob)
eq(Fib.decode_bytes(bits, #blob), blob, "byte-stream round-trip")

-- 6. Bit pack/unpack round-trip (with non-multiple-of-8 length).
local packed, len = Fib.pack_bits(bits)
eq(Fib.unpack_bits(packed, len), bits, "pack/unpack bit round-trip")

-- 7. Full pipeline: bytes -> bits -> packed -> bits -> bytes.
local packed2, len2 = Fib.pack_bits(Fib.encode_bytes(blob))
eq(Fib.decode_bytes(Fib.unpack_bits(packed2, len2), #blob), blob, "packed byte pipeline")

-- 8. Invalid input is rejected.
local ok = pcall(Fib.encode, 0)
check(not ok, "encode(0) rejected")
ok = pcall(Fib.encode, 1.5)
check(not ok, "encode(1.5) rejected")

io.write(string.format("fibonacci codec: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
