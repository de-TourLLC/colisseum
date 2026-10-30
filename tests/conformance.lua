--[[
    Conformance / differential runner for the register VM. Each case is
    { name, source, expected }: the source ends in `return <expr>` and the VM must
    hand back `expected`. A parse/compile error is a failure -- that is how we see
    what the VM doesn't handle yet. Covers the Lua baseline, the Luau additions
    (continue, interpolation, if-else expr, numeric separators, \u), metamethods,
    coroutines and a reproducibility check. Run: luajit tests/conformance.lua
]]
package.path = "./?.lua;./?/init.lua;" .. package.path

local RegVM = require("src.core.reg-vm")

local cases = {
    -- Lua baseline (must always pass)
    { "arith",            "return 2+3*4-10/2", 9 },
    { "while+break",      "local i=0 while true do i=i+1 if i==7 then break end end return i", 7 },
    { "numeric for",      "local s=0 for i=1,10 do s=s+i end return s", 55 },
    { "generic for",      "local t={5,6,7} local s=0 for _,v in ipairs(t) do s=s+v end return s", 18 },

    -- J2: continue
    { "continue/for",     "local s=0 for i=1,10 do if i%2==0 then continue end s=s+i end return s", 25 },
    { "continue/while",   "local s=0 local i=0 while i<10 do i=i+1 if i%2==0 then continue end s=s+i end return s", 25 },
    { "continue/forin",   "local t={1,2,3,4,5,6} local s=0 for _,v in ipairs(t) do if v>3 then continue end s=s+v end return s", 6 },
    { "continue/repeat",  "local s=0 local i=0 repeat i=i+1 if i%2==0 then continue end s=s+i until i>=10 return s", 25 },

    -- J2: string interpolation
    { "interp/simple",    "local x=42 return `val {x}`", "val 42" },
    { "interp/multi",     "local a,b=3,4 return `{a}+{b}={a+b}`", "3+4=7" },
    { "interp/expr",      "local t={n=5} return `n is {t.n*2}`", "n is 10" },
    { "interp/plain",     "return `no braces here`", "no braces here" },

    -- J2: if-else expression
    { "ifexpr/true",      "local x=5 return if x>0 then \"pos\" else \"neg\"", "pos" },
    { "ifexpr/false",     "local x=-5 return if x>0 then \"pos\" else \"neg\"", "neg" },
    { "ifexpr/elseif",    "local x=0 return if x>0 then 1 elseif x<0 then -1 else 0", 0 },

    -- J2: numeric separators
    { "numsep",           "return 1_000_000 + 2_000", 1002000 },

    -- J2: \u escape
    { "u-escape",         "return #\"\\u{48}\\u{49}\"", 2 },

    -- J2: edge cases
    { "continue/nested",  "local c=0 for a=1,3 do for b=1,3 do if b==2 then continue end c=c+1 end end return c", 6 },
    { "continue+break",   "local s=0 for i=1,10 do if i==8 then break end if i%2==0 then continue end s=s+i end return s", 16 },
    { "interp/method",    "local s='ab' return `len {s:upper()}`", "len AB" },
    { "interp/escape",    "return `a\\`b`", "a`b" },
    { "ifexpr/nested",    "local x=5 return if x>10 then \"big\" else if x>0 then \"pos\" else \"neg\"", "pos" },

    -- D2: metamethods + stdlib semantics (corners a VM commonly gets wrong)
    { "mt/__index fn",    "local o=setmetatable({},{__index=function(_,k) return k..'!' end}) return o.hi", "hi!" },
    { "mt/__index tbl",   "local base={x=9} local o=setmetatable({},{__index=base}) return o.x", 9 },
    { "mt/__newindex",    "local store={} local o=setmetatable({},{__newindex=function(_,k,v) store[k]=v*2 end}) o.a=5 return store.a", 10 },
    { "mt/__call",        "local o=setmetatable({},{__call=function(_,n) return n+1 end}) return o(41)", 42 },
    { "mt/__eq",          "local m={__eq=function() return true end} local a=setmetatable({},m) local b=setmetatable({},m) return a==b and 1 or 0", 1 },
    { "mt/__lt/__le",     "local m={__lt=function() return true end,__le=function() return false end} local a=setmetatable({},m) local b=setmetatable({},m) return (a<b and 1 or 0)+(a<=b and 10 or 0)", 1 },
    { "mt/__concat",      "local o=setmetatable({},{__concat=function() return 'z' end}) return (o..'x')..('y'..o)", "zz" },
    { "mt/__len",         "local o=setmetatable({},{__len=function() return 7 end}) return #o", 7 },
    { "mt/__unm",         "local o=setmetatable({v=3},{__unm=function(s) return -s.v end}) return -o", -3 },
    { "string.format",    "return string.format('%d-%s', 7, 'x')", "7-x" },
    { "string methods",   "local s='abcabc' return select('#', s:gsub('a','Z')) >= 1 and (s:gsub('a','Z')) or '?'", "ZbcZbc" },
    { "table.sort",       "local t={3,1,2} table.sort(t) return t[1]*100+t[2]*10+t[3]", 123 },
    { "table.insert/rem", "local t={1,2} table.insert(t,3) table.remove(t,1) return t[1]*10+t[2]", 23 },
    { "select slice",     "local function f(...) return select(2, ...) end return (f(10,20,30))", 20 },
    { "pcall/error tbl",  "local ok,e=pcall(function() error({code=42}) end) return (not ok) and e.code or -1", 42 },
    { "nested upvalue",   "local function mk() local n=0 local function inc() n=n+1 end local function get() return n end inc() inc() return get() end return mk()", 2 },
    { "for float step",   "local s=0 for i=0,1,0.25 do s=s+1 end return s", 5 },
    { "for neg step",     "local s='' for i=3,1,-1 do s=s..i end return s", "321" },
    { "multi mid vararg", "local function f(...) return 1, ..., 9 end local a,b,c=f(5) return a*100+b*10+c", 159 },

    -- D2b: coroutines, varargs, string/math/table edges
    { "coroutine wrap",   "local g=coroutine.wrap(function() for i=1,3 do coroutine.yield(i) end end) return g()+g()*10+g()*100", 321 },
    { "coroutine resume", "local c=coroutine.create(function(a) local b=coroutine.yield(a+1) return b*2 end) local _,x=coroutine.resume(c,10) local _,y=coroutine.resume(c,5) return x*100+y", 1110 },
    { "vararg in table",  "local function f(...) return {...} end local t=f(2,4,6) return #t + t[1] + t[3]", 11 },
    { "vararg select neg","local function f(...) return select('#', ...) end return f(1,2,3,nil,nil)", 5 },
    { "string.rep/sub",   "local s=('ab'):rep(3) return s:sub(2,5)", "baba" },
    { "string.byte multi","local a,b,c=('ABC'):byte(1,3) return a+b+c", 198 },
    { "math huge/nan",    "local inf=math.huge local nan=inf-inf return (inf>1e300 and 1 or 0)+(nan~=nan and 10 or 0)", 11 },
    { "neg index sub",    "return ('hello'):sub(-3)", "llo" },
    { "table.concat sep", "return table.concat({1,2,3}, '-')", "1-2-3" },
    { "chained method",   "local s='  hi  ' return '['..s:gsub('%s+','')..']'", "[hi]" },
    { "and/or sideeffect","local log={} local function tap(v) log[#log+1]=v return v end local r=tap(false) or tap(7) return r*10+#log", 72 },
    { "dotted func def",  "local M={a={}} function M.a.add(x,y) return x+y end return M.a.add(19,23)", 42 },
}

local passed, failed, failures = 0, 0, {}
for _, case in ipairs(cases) do
    local name, source, expected = case[1], case[2], case[3]
    local ok, result = pcall(function() return RegVM.execute(source) end)
    local got = ok and result and result[1]
    if ok and got == expected then
        passed = passed + 1
    else
        failed = failed + 1
        local why = ok and ("got " .. tostring(got) .. ", want " .. tostring(expected))
            or ("error: " .. tostring(result):gsub("^.-:%d+: ", ""):sub(1, 70))
        failures[#failures + 1] = string.format("  FAIL %-16s %s", name, why)
    end
end

--[[ a seeded fortress build (exercises the whole J2 lowering path) must be byte-
     identical across runs, and differ without a seed. ]]
local Obfuscator = require("src.obfuscator")
local J2SRC = "local p={} for i=1,8 do if i%3==0 then continue end p[#p+1]=i end " ..
    "local n=#p local lab=`n={n} first={p[1]}` local s=if n>3 then \"many\" else \"few\" return lab,s,1_000+n"
local function build(seed) return Obfuscator.obfuscate(J2SRC, { preset = "fortress", target = "luau", seed = seed }) end
if build(7) == build(7) then passed = passed + 1 else failed = failed + 1; failures[#failures + 1] = "  FAIL reproducible   seeded builds differ" end
if build(7) ~= build(8) then passed = passed + 1 else failed = failed + 1; failures[#failures + 1] = "  FAIL divergence     different seeds identical" end

-- J11: a mismatched blob self-hash latches the silent drift (patched blob => wrong result).
do
    local RegRuntime = require("src.core.reg-runtime")
    local function H(s) local h = 2166136261 % 2147483647; for i = 1, #s do h = (h + s:byte(i) * 16777619) % 2147483647; h = (h * 48271) % 2147483647 end return h end
    local prog = RegVM.opaque(RegVM.compile("return 10+20"))
    prog.h = H(prog.S)
    local clean = RegRuntime.run(prog)[1]
    prog.h = H(prog.S) + 1
    local tampered = RegRuntime.run(prog)[1]
    if clean == 30 and tampered ~= 30 then passed = passed + 1
    else failed = failed + 1; failures[#failures + 1] = "  FAIL J11 self-hash  clean=" .. tostring(clean) .. " tampered=" .. tostring(tampered) end
end

io.write(string.format("conformance (register VM): %d passed, %d failed\n", passed, failed))
for _, line in ipairs(failures) do io.write(line .. "\n") end
os.exit(failed == 0 and 0 or 1)
