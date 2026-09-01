-- Differential correctness harness for the register-based VM backend.
--
-- Oracle = reference Lua/LuaJIT (loadstring of the source). Candidate =
-- `require("src.core.reg-vm").execute(source)`, which must return a table whose
-- [1] equals the source's first return value. Every case below must match the
-- oracle exactly. This is the acceptance target for the register VM: it defines
-- "correct". Expand the corpus freely; never weaken a case to make it pass.
package.path = "./?.lua;./?/init.lua;" .. package.path

local ok_mod, RegVM = pcall(require, "src.core.reg-vm")
if not ok_mod then
    io.write("reg-vm module not present yet: " .. tostring(RegVM):sub(1, 80) .. "\n")
    os.exit(1)
end

-- Each case: { name, source }. The source ends in a `return <expr>`; the harness
-- compares the register VM's first returned value against reference Lua.
local cases = {
    { "arith",            "local a=40 local b=2 return a+b" },
    { "precedence",       "return 2+3*4-10/2" },
    { "floor/mod/pow",    "return math.floor(17/5) + 17%5 + 2^8" },
    { "concat",           "return 'a'..1 ..'b'..2" },
    { "compare chain",    "return (1<2) and (2<=2) and (3>2) and (3>=3) and (1~=2) and (2==2)" },
    { "and/or short",     "local x=nil return (x or 'd')..(x and 'y' or 'n')" },
    { "not/len",          "local s='abcd' return (not false) and #s or -1" },
    { "unary minus",      "local x=5 return -x + -(-3)" },
    { "if/elseif/else",   "local x=3 if x==1 then return 10 elseif x==2 then return 20 elseif x==3 then return 30 else return 0 end" },
    { "while",            "local s=0 local i=1 while i<=100 do s=s+i i=i+1 end return s" },
    { "while+break",      "local i=0 while true do i=i+1 if i==7 then break end end return i" },
    { "repeat",           "local i=0 repeat i=i+1 until i>=5 return i" },
    { "repeat+break",     "local i=0 repeat i=i+1 if i==3 then break end until i>=99 return i" },
    { "numeric for",      "local s=0 for i=1,10 do s=s+i end return s" },
    { "for step",         "local s=0 for i=10,1,-2 do s=s*10+i end return s" },
    { "for+break",        "local last=0 for i=1,100 do last=i if i==5 then break end end return last" },
    { "nested for+break", "local c=0 for a=1,3 do for b=1,3 do if b==2 then break end c=c+1 end end return c" },
    { "generic ipairs",   "local t={5,6,7} local s=0 for _,v in ipairs(t) do s=s+v end return s" },
    { "generic pairs",    "local t={a=1,b=2,c=3} local s=0 for k,v in pairs(t) do s=s+v end return s" },
    { "generic+break",    "local t={10,20,30,40} local s=0 for _,v in ipairs(t) do if v>=30 then break end s=s+v end return s" },
    { "func call",        "local function f(a,b) return a*b end return f(6,7)" },
    { "recursion",        "local function f(n) if n<2 then return n end return f(n-1)+f(n-2) end return f(15)" },
    { "mutual recursion", "local function ev(n) if n==0 then return true end return od(n-1) end function od(n) if n==0 then return false end return ev(n-1) end return ev(10)" },
    { "closure counter",  "local function mk() local n=0 return function() n=n+1 return n end end local c=mk() c() c() return c()" },
    { "closure capture",  "local function add(x) return function(y) return x+y end end return add(40)(2)" },
    { "varargs count",    "local function f(...) return select('#',...) end return f(1,nil,3,nil)" },
    { "varargs sum",      "local function f(...) local s=0 for _,v in ipairs({...}) do s=s+v end return s end return f(1,2,3,4)" },
    { "vararg passthru",  "local function g(a,b,c) return (a or 0)+(b or 0)+(c or 0) end local function f(...) return g(...) end return f(1,2,3)" },
    { "multi return",     "local function f() return 1,2,3 end local a,b,c=f() return a*100+b*10+c" },
    { "multi assign",     "local a,b,c=1,2,3 a,b=b,a return a*100+b*10+c" },
    { "swap",             "local a,b=1,2 a,b=b,a return a*10+b" },
    { "table array",      "local t={10,20,30} return t[1]+t[2]+t[3]" },
    { "table hash",       "local t={x=5,y=7} return t.x+t.y" },
    { "table mixed",      "local t={1,2,x=3,[4]=4} return t[1]+t[2]+t.x+t[4]" },
    { "table nested",     "local t={a={b={c=42}}} return t.a.b.c" },
    { "table len",        "local t={1,2,3,4,5} return #t" },
    { "table assign",     "local t={} for i=1,5 do t[i]=i*i end return t[1]+t[2]+t[3]+t[4]+t[5]" },
    { "method colon",     "local o={v=10} function o:add(n) self.v=self.v+n return self.v end return o:add(5)" },
    { "method chain",     "local o={v=0} function o:add(n) self.v=self.v+n return self end o:add(3):add(4) return o.v" },
    { "dotted func",      "local M={} function M.new(x) return x*2 end return M.new(21)" },
    { "metatable index",  "local base={greet=function() return 7 end} local o=setmetatable({},{__index=base}) return o.greet()" },
    { "metatable add",    "local mt={__add=function(a,b) return a.v+b.v end} local x=setmetatable({v=3},mt) local y=setmetatable({v=4},mt) return x+y" },
    { "pcall ok",         "local ok,v=pcall(function() return 42 end) return ok and v or -1" },
    { "pcall err",        "local ok,e=pcall(function() error('boom') end) return (not ok) and (tostring(e):match('boom') and 1 or 0) or -1" },
    { "string upper",     "return ('hello'):upper()" },
    { "string format",    "return string.format('%d-%s', 7, 'z')" },
    { "string gsub",      "local s=string.gsub('a,b,c',',','-') return s" },
    { "string sub/find",  "local s='abcdef' return s:sub(2,4)..tostring(s:find('cd'))" },
    { "table.concat",     "local t={} for i=1,5 do t[i]=tostring(i) end return table.concat(t,',')" },
    { "table.sort",       "local t={3,1,2} table.sort(t) return t[1]*100+t[2]*10+t[3]" },
    { "select tail",      "local function f(...) return select(2,...) end return (f(9,8,7))" },
    { "tonumber/tostring","return tonumber('0x1F') + #tostring(12345)" },
    { "nil in table",     "local t={} t.x=nil t.y=5 local c=0 for k in pairs(t) do c=c+1 end return c*100+t.y" },
    { "semicolons",       "local a=1; local b=2; return a+b" },
    { "deep recursion",   "local function s(n) if n==0 then return 0 end return n+s(n-1) end return s(200)" },
    { "for-var capture",   "local t={} for i=1,3 do t[i]=function() return i end end return t[1]()+t[2]()+t[3]()" },
    { "forin-var capture", "local fns={} for _,v in ipairs({10,20,30}) do fns[#fns+1]=function() return v end end return fns[1]()+fns[2]()+fns[3]()" },
    { "for-var capture 1",  "local s=0 for i=1,4 do local f=function() return i*i end s=s+f() end return s" },
    { "coroutine yield",   "local co=coroutine.wrap(function() for i=1,3 do coroutine.yield(i*10) end return 99 end) return co()+co()+co()+co()" },
    { "coroutine resume",  "local function g(n) for i=1,n do coroutine.yield(i*i) end end local co=coroutine.create(g) local t={} local ok,v=coroutine.resume(co,4) while ok and v do t[#t+1]=v ok,v=coroutine.resume(co) end return t[1]+t[2]+t[3]+t[4]" },
}

local passed, failed = 0, 0
for _, case in ipairs(cases) do
    local name, source = case[1], case[2]
    local ref_fn = loadstring("return (function() " .. source .. " end)()")
    local ref_ok, ref_val = pcall(ref_fn)
    local got_ok, got = pcall(function()
        local r = RegVM.execute(source)
        return r and r[1]
    end)
    if ref_ok and got_ok and got == ref_val then
        passed = passed + 1
    else
        failed = failed + 1
        io.write(string.format("  FAIL %-18s want=%s got=%s\n", name,
            tostring(ref_val), got_ok and tostring(got) or ("ERR:" .. tostring(got):gsub("\n", " "):sub(1, 60))))
    end
end
io.write(string.format("register VM differential: %d/%d\n", passed, passed + failed))
if failed > 0 then os.exit(1) end
