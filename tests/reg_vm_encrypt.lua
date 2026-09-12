-- Register VM ChaCha20 stream-cipher layer: build a program, encode_opaque with
-- encryption on, and require the VM (which derives the identical RFC 8439 keystream
-- from the fog) to return the same result as the plaintext build. Also covers the
-- encrypt + Fibonacci combination. Guards reg-runtime's inline ChaCha vs chacha.lua.
local function project_root()
    local source = debug.getinfo(1, "S").source:sub(2)
    return source:match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."
end
local root = project_root()
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local RegCompiler = require("src.core.reg-compiler")
local RegBytecode = require("src.core.reg-bytecode")
local Runtime = require("src.core.reg-runtime")
local Fibonacci = require("src.core.fibonacci")
local ChaCha = require("src.core.chacha")

local passed, failed = 0, 0
local function ok(cond, msg) if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: " .. msg .. "\n") end end

-- ChaCha20 known-answer test (RFC 8439 section 2.3.2).
do
    local key = { 0x03020100, 0x07060504, 0x0b0a0908, 0x0f0e0d0c, 0x13121110, 0x17161514, 0x1b1a1918, 0x1f1e1d1c }
    local nonce = { 0x09000000, 0x4a000000, 0x00000000 }
    local ks = ChaCha.keystream(key, nonce, 1, 16)
    local want = { 0x10, 0xf1, 0xe7, 0xe4, 0xd1, 0x3b, 0x59, 0x15, 0x50, 0x0f, 0xdd, 0x1f, 0xa3, 0x20, 0x71, 0xc4 }
    local good = true
    for i = 1, 16 do if ks[i] ~= want[i] then good = false end end
    ok(good, "ChaCha20 RFC 8439 KAT")
end

local cases = {
    "return 1+2",
    "local x=10 local y=20 return x*y-3",
    "local t={} for i=1,50 do t[i]=i*i end local s=0 for i=1,50 do s=s+t[i] end return s",
    "local function fib(n) if n<2 then return n end return fib(n-1)+fib(n-2) end return fib(18)",
    "local s='' for i=1,20 do s=s..tostring(i)..',' end return s",
    "return ('hello world'):upper():rep(3)",
    "local x=3.14159 return math.floor(x*100)/100",
    "local ok,err=pcall(function() error('boom') end) return tostring(ok)",
}
for _, src in ipairs(cases) do
    local fog = { 7, 42, 99, 13, 200, 1, 250 }
    local ref = Runtime.run({ S = (RegBytecode.encode_opaque(RegCompiler.compile(src), fog, false)), f = fog,
        r = select(2, RegBytecode.encode_opaque(RegCompiler.compile(src), fog, false)) })[1]
    local encblob, regs = RegBytecode.encode_opaque(RegCompiler.compile(src), fog, true)
    local enc = Runtime.run({ S = encblob, f = fog, r = regs, enc = true })[1]
    local packed, bitlen = Fibonacci.pack_bits(Fibonacci.encode_bytes(encblob))
    local encfib = Runtime.run({ S = packed, f = fog, r = regs, enc = true, fib = bitlen })[1]
    ok(tostring(ref) == tostring(enc) and tostring(ref) == tostring(encfib), "encrypt/enc+fib matches plain: " .. src)
end

io.write(string.format("register VM encrypt layer: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
