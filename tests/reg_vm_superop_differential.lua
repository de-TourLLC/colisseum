-- Superoperator differential: compile -> fuse (ALL kinds forced) -> run on the
-- register VM, and require the first return value to match reference Lua exactly.
-- Exercises the fusable straight-line pairs plus control flow that jumps around
-- them (a jump must land on the preserved second slot, never mid-fusion).
package.path = "./?.lua;./?/init.lua;" .. package.path
local RegVM = require("src.core.reg-vm")
local RegBytecode = require("src.core.reg-bytecode")
local loadfn = loadstring or load

local cases = {
    { "many locals (MOVE;MOVE)",   "local a=1 local b=2 local c=3 local x=a local y=b local z=c return x+y+z" },
    { "swaps",                     "local a,b,c=1,2,3 a,b=b,a b,c=c,b return a*100+b*10+c" },
    { "many consts (LOADK;LOADK)", "local a=10 local b=20 local c=30 local d=40 return a+b+c+d" },
    { "global calls (GETGLOBAL)",  "local s=tostring(1)..tostring(2) return #s + math.floor(2.9) + math.floor(3.9)" },
    { "mixed globals",             "return math.floor(5/2) + math.max(1,9) + math.min(4,2)" },
    { "loop over fused prologue",  "local a=1 local b=2 local c=3 local s=0 for i=1,5 do s=s+a+b+c end return s" },
    { "branch skips fused pair",   "local a=1 local b=2 local x=0 if a<b then x=10 else local p=a local q=b x=p+q end return x" },
    { "branch into second half",   "local a=5 local b=6 local r=0 for i=1,3 do local p=a local q=b if i==2 then r=r+p else r=r+q end end return r" },
    { "recursion + fused",         "local function f(n) local one=1 local two=2 if n<two then return n end return f(n-one)+f(n-two) end return f(12)" },
    { "closures + fused",          "local function mk(x) local base=x local step=2 return function() base=base+step return base end end local c=mk(10) c() c() return c()" },
    { "while + fused body",        "local a=3 local b=4 local i=0 local s=0 while i<10 do local p=a local q=b s=s+p+q i=i+1 end return s" },
    { "table build",               "local t={} local one=1 local two=2 t[one]=10 t[two]=20 return t[1]+t[2]" },
    { "nested fused + return",     "local function g() local a=7 local b=8 local c=9 return a+b+c end return g()*2" },
}

local passed, failed = 0, 0
for _, case in ipairs(cases) do
    local name, src = case[1], case[2]
    local ref_chunk = assert(loadfn("return (function() " .. src .. " end)()"))
    local ref = ref_chunk()
    local proto = RegVM.compile(src)
    RegBytecode.fuse(proto, nil) -- force ALL fusion kinds
    local ok, got = pcall(function() return RegVM.run(proto) end)
    if ok and got[1] == ref then
        passed = passed + 1
    else
        failed = failed + 1
        io.write("FAIL " .. name .. " : expected " .. tostring(ref) ..
            ", got " .. (ok and tostring(got[1]) or ("ERROR " .. tostring(got))) .. "\n")
    end
end
io.write("register VM superop differential: " .. passed .. "/" .. (passed + failed) .. "\n")
os.exit(failed == 0 and 0 or 1)
