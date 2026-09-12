-- numeric-fibonacci differential test: for a range of sources, the transformed
-- program must load and return exactly what the original does, and carry no
-- plaintext copy of the pooled integer literals.
local function project_root()
    local source = debug.getinfo(1, "S").source:sub(2)
    return source:match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."
end
local root = project_root()
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local NF = require("src.steps.literals.numeric-fibonacci")

local passed, failed = 0, 0
local function ok(cond, msg) if cond then passed = passed + 1 else failed = failed + 1; io.write("FAIL: " .. msg .. "\n") end end

local load_fn = loadstring or load

local cases = {
    "return 1337",
    "local t={} for i=1,25 do t[i]=i*7+3 end local s=0 for i=1,25 do s=s+t[i] end return s",
    "local function clamp(v,lo,hi) if v<lo then return lo elseif v>hi then return hi end return v end return clamp(500,10,99)",
    "local a={100,200,300,[42]=7} return a[1]+a[2]+a[3]+a[42]",
    "return 2^16, 1000000+337, 65535",
    "local s='' for i=10,15 do s=s..i end return s",
    "return ('x'):rep(50)",
}

for _, src in ipairs(cases) do
    local out = NF.apply(src, { seed = "t", min_value = 3 })
    -- transformed source must still parse+run and match the original's returns.
    local of = load_fn(src); local nf = load_fn(out)
    ok(of ~= nil and nf ~= nil, "both load: " .. src)
    if of and nf then
        local o = { of() }; local n = { nf() }
        local same = (#o == #n)
        for i = 1, #o do if tostring(o[i]) ~= tostring(n[i]) then same = false end end
        ok(same, "same result: " .. src)
    end
end

-- Idempotence / determinism: same seed -> identical output.
local a = NF.apply("return 1234+5678", { seed = "z" })
local b = NF.apply("return 1234+5678", { seed = "z" })
ok(a == b, "deterministic under a fixed seed")
-- The large literals should no longer appear verbatim.
ok(a:find("1234", 1, true) == nil and a:find("5678", 1, true) == nil, "no plaintext pooled literals")

io.write(string.format("numeric-fibonacci: %d passed, %d failed\n", passed, failed))
if failed > 0 then os.exit(1) end
