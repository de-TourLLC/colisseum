package.path = "./?.lua;./?/init.lua;" .. package.path
local O = require("src.obfuscator")
local cases = {
 {"basic arith","local a=40 local b=2 return a+b",42},
 {"if/else","local x=5 if x>3 then return 1 else return 0 end",1},
 {"while","local s=0 local i=1 while i<=10 do s=s+i i=i+1 end return s",55},
 {"numeric for","local s=0 for i=1,10 do s=s+i end return s",55},
 {"func def+call","local function f(a,b) return a*b end return f(6,7)",42},
 {"table literal","local t={10,20,30} return t[1]+t[2]+t[3]",60},
 {"table field","local t={x=5,y=7} return t.x+t.y",12},
 {"generic for","local t={1,2,3} local s=0 for _,v in ipairs(t) do s=s+v end return s",6},
 {"multiple assign","local a,b,c=1,2,3 return a*100+b*10+c",123},
 {"varargs","local function f(...) local s=0 for _,v in ipairs({...}) do s=s+v end return s end return f(1,2,3,4)",10},
 {"closures","local function counter() local n=0 return function() n=n+1 return n end end local c=counter() c() c() return c()",3},
 {"length #","local s='a'..'b'..'c' return #s",3},
 {"string method","local s='hello' return s:upper()","HELLO"},
 {"nested func expr","local f=function(x) return function(y) return x+y end end return f(40)(2)",42},
 {"for break","local i=0 for k=1,10 do i=k if k==3 then break end end return i",3},
 {"while true break","local i=0 while true do i=i+1 if i==7 then break end end return i",7},
 {"repeat break","local i=0 repeat i=i+1 if i==4 then break end until i>=99 return i",4},
 {"nested break inner","local c=0 for a=1,3 do for b=1,3 do if b==2 then break end c=c+1 end end return c",3},
 {"forin break","local t={10,20,30,40} local s=0 for _,v in ipairs(t) do if v>=30 then break end s=s+v end return s",30},
 {"dotted function def","local M={} function M.new(x) return x*2 end return M.new(21)",42},
 {"method function def","local o={v=10} function o:add(n) self.v=self.v+n return self.v end return o:add(5)",15},
 {"semicolon statements","local a=1; local b=2; return a+b",3},
 {"table semicolon sep","local t={1;2;3} return t[1]+t[2]+t[3]",6},
 {"table trailing comma","local t={4,5,6,} return #t",3},
 {"compound assign","local x=5 x+=3 x*=2 x-=1 return x",15},
 {"compound member","local t={n=10} t.n+=5 t.n*=2 return t.n",30},
 {"compound concat","local s='a' s..='b' s..='c' return s","abc"},
 {"generic function","local function id<T>(x) return x*2 end return id(21)",42},
 {"generic dotted def","local M={} function M.map<T>(x) return x+1 end return M.map(41)",42},
}
local ok = 0
for i, c in ipairs(cases) do
  local okr, vals = pcall(O.execute, c[2])
  local got = okr and vals and vals[1]
  if okr and got == c[3] then ok = ok + 1
  else io.write(string.format("  FAIL %-16s want=%s got=%s\n", c[1], tostring(c[3]), okr and tostring(got) or ("ERR:"..tostring(vals):gsub("\n"," "):sub(1,55)))) end
end
io.write(ok .. "/" .. #cases .. "\n")
if ok < #cases then os.exit(1) end
