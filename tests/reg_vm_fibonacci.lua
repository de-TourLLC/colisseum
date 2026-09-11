-- Register VM Fibonacci (Zeckendorf) blob layer: build a program, encode_opaque to
-- a fogged blob, then run it plain vs Fibonacci bit-packed and require identical
-- results. Guards that reg-runtime's fib_unpack mirrors src/core/fibonacci.lua.
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

local cases = {
    "return 1+2",
    "local x=10 local y=20 return x*y-3",
    "local t={} for i=1,50 do t[i]=i*i end local s=0 for i=1,50 do s=s+t[i] end return s",
    "local function fib(n) if n<2 then return n end return fib(n-1)+fib(n-2) end return fib(15)",
    "local s='' for i=1,20 do s=s..tostring(i)..',' end return s",
    "local a={1,2,3,4,5} local m=0 for _,v in ipairs(a) do if v>m then m=v end end return m",
    "return ('hello world'):upper():rep(3)",
    "local x=3.14159 return math.floor(x*100)/100",
    "local ok,err=pcall(function() error('boom') end) return tostring(ok)..':'..tostring(err ~= nil)",
    "local n=143 local c=0 while n>0 do n=math.floor(n/2) c=c+1 end return c",
}

local passed, failed = 0, 0
for _, src in ipairs(cases) do
    local proto = RegCompiler.compile(src)
    local fog = { 7, 42, 99, 13, 200, 1 }
    local blob, regs = RegBytecode.encode_opaque(proto, fog)
    local plain = Runtime.run({ S = blob, f = fog, r = regs })
    local packed, bitlen = Fibonacci.pack_bits(Fibonacci.encode_bytes(blob))
    local fibres = Runtime.run({ S = packed, f = fog, r = regs, fib = bitlen })
    if tostring(plain[1]) == tostring(fibres[1]) then
        passed = passed + 1
    else
        failed = failed + 1
        io.write("FAIL: " .. src .. "\n  plain=" .. tostring(plain[1]) .. " fib=" .. tostring(fibres[1]) .. "\n")
    end
end

io.write(string.format("register VM Fibonacci layer: %d/%d\n", passed, passed + failed))
if failed > 0 then os.exit(1) end
