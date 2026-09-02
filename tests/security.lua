-- Colisseum security evidence suite.
--
-- Verifies the obfuscator's defensive properties end-to-end WITHOUT loadstring:
-- every execution goes through the internal tree-walker register VM
-- (Obfuscator.execute), never through Lua's load*.
--
-- Coverage:
--   * seeded builds are byte-identical; unseeded and differently-seeded builds diverge
--   * no source plaintext (identifiers, fragments) survives into any preset
--   * no loadstring / load() / fixed __fiu markers anywhere in VM backends
--   * single identifier scheme `coli_*` across the whole production (no legacy brand)
--   * differential battery: 12 programs x 5 text presets, original vs obfuscated,
--     executed on the tree-walker register VM
--   * runtime-integrity guard fires when its own expected hash is patched (0x5C08)
--   * anti-tamper guard fires when its internal nonce digest is patched (0x7A31)
--   * ChaCha20 seal (Package.seal) rejects a corrupted encrypted payload (0x3E9D)
--   * fortress bundle executes on the tree-walker register VM and returns 42

local ss = debug.getinfo(1, "S").source:sub(2)
local root = ss:match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local Obfuscator = require("src.obfuscator")
local Crypto = require("src.steps.security.crypto")
local RuntimeIntegrity = require("src.steps.anti.runtime-integrity")
local AntiTamper = require("src.steps.anti.anti-tamper")
local Package = require("src.core.luau-package")

local passed = 0
local function check(condition, message)
    if condition then
        passed = passed + 1
        print("PASS " .. message)
    else
        error("FAIL: " .. message, 2)
    end
end

local VM = { steps = 2000000000, loop_iterations = 5000000, depth = 400 }

local function run(source)
    return Obfuscator.execute(source, VM)
end

local function run_probe(source)
    local ok, values = pcall(run, source)
    return ok, values
end

local function build(source, preset, seed)
    return Obfuscator.obfuscate(source, { preset = preset, target = "lua", seed = seed })
end

local SRC = "local total = 0\nlocal function double(x) return x * 2 end\ntotal = double(21)\nreturn total"

-- ---------------------------------------------------------------------------
-- 1. Reproducibility: seeded builds are byte-identical.
-- ---------------------------------------------------------------------------
local fortress_a = build(SRC, "fortress", 7)
local fortress_b = build(SRC, "fortress", 7)
check(fortress_a == fortress_b, "reproducible fortress: same seed => byte-identical output")

local total_a = build(SRC, "total", 11)
local total_b = build(SRC, "total", 11)
check(total_a == total_b, "reproducible total: same seed => byte-identical output")

-- ---------------------------------------------------------------------------
-- 2. Divergence: different seeds and unseeded builds must differ.
-- ---------------------------------------------------------------------------
local fortress_c = build(SRC, "fortress", 8)
check(fortress_a ~= fortress_c, "per-build divergence: different seeds differ")

local unseeded = build(SRC, "fortress", nil)
local unseeded2 = build(SRC, "fortress", nil)
check(unseeded ~= unseeded2, "per-build divergence: un-seeded builds differ")

-- ---------------------------------------------------------------------------
-- 3. No plaintext survives.
-- ---------------------------------------------------------------------------
local fragments = {
    "total = double(21)",
    "local total = 0",
    "local function double",
    "double(21)",
    "total",
    "double",
}
local secure_a = build(SRC, "secure", 5)
for _, build_output in ipairs({ fortress_a, secure_a, total_a }) do
    for _, fragment in ipairs(fragments) do
        check(not build_output:find(fragment, 1, true), "output leaks plaintext fragment: " .. fragment)
    end
end

local reserved = {
    ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true,
    ["end"] = true, ["false"] = true, ["for"] = true, ["function"] = true, ["if"] = true,
    ["in"] = true, ["local"] = true, ["nil"] = true, ["not"] = true, ["or"] = true,
    ["repeat"] = true, ["return"] = true, ["then"] = true, ["true"] = true, ["until"] = true,
    ["while"] = true,
}
local source_words = {}
for word in SRC:gmatch("[%a_][%w_]*") do source_words[word] = true end
local presets = { "easy", "medium", "hard", "full", "secure", "fortress", "total" }
local leaks = {}
for _, preset in ipairs(presets) do
    local output = build(SRC, preset, 3)
    for word in output:gmatch("[%a_][%w_]*") do
        if #word >= 4 and not reserved[word] and source_words[word] then
            leaks[leaks[#leaks + 1]] = preset .. " leaked identifier: " .. word
        end
    end
end
check(#leaks == 0, "every preset output carries no source plaintext (leaks: " .. #leaks .. ")")

-- ---------------------------------------------------------------------------
-- 4. Bytecode never appears as the plaintext CLBC header.
-- ---------------------------------------------------------------------------
for _, preset in ipairs({ "fortress", "total", "secure" }) do
    local output = build(SRC, preset, 9)
    check(not output:find("CLBC", 1, true), preset .. " does not leak the raw CLBC bytecode header")
end

-- ---------------------------------------------------------------------------
-- 5. No loadstring / load() / fixed __fiu markers in any VM backend.
-- ---------------------------------------------------------------------------
for _, preset in ipairs({ "fortress", "total" }) do
    local output = build(SRC, preset, 12)
    check(not output:find("loadstring", 1, true), preset .. " contains no loadstring")
    check(not output:find("load(", 1, true), preset .. " contains no load(")
    check(not output:find("__fiu", 1, true), preset .. " contains no fixed __fiu marker")
    check(not output:find("__bytecode", 1, true), preset .. " contains no fixed __bytecode marker")
    check(not output:find("_j=function", 1, true), preset .. " contains no fixed register-VM marker")
end

-- ---------------------------------------------------------------------------
-- 6. Sole identifier scheme: coli_ everywhere, no legacy brand.
-- ---------------------------------------------------------------------------
for _, preset in ipairs(presets) do
    local output = build(SRC, preset, 4)
    check(output:find("coli_", 1, true) ~= nil, preset .. " uses the coli_ identifier family")
    check(not output:find("itzKatzito", 1, true) and not output:find("itzCool", 1, true), preset .. " carries no legacy itz brand")
end

-- ---------------------------------------------------------------------------
-- 7. Differential battery: 12 programs x 5 text presets.
-- ---------------------------------------------------------------------------
local BATTERY = {
    { name = "arithmetic", code = "return (1 + 2) * 3 - 4 / 2" },
    { name = "string-literal", code = 'return "hello" .. " " .. "world"' },
    { name = "table-shapes", code = 'local t = { a = 1, b = { 2, 3 }, [1] = "x" } return #t.b + t.a + #t' },
    { name = "closures", code = "local function mk(n) return function(x) return x + n end end local f = mk(10) return f(5)" },
    { name = "varargs-count", code = "local function multi(...) return select('#', ...) end return multi(1, nil, 3)" },
    { name = "nested-loops", code = "local n = 0 for i = 1, 3 do for j = 1, 3 do n = n + i * j end end return n" },
    { name = "recursion", code = "local function fib(n) if n < 2 then return n end return fib(n - 1) + fib(n - 2) end return fib(12)" },
    { name = "repeat-scope", code = "local total = 0 repeat total = total + 1 until total >= 5 return total" },
    { name = "varargs-sum", code = "local function sum(...) local t = 0 for _, v in ipairs({ ... }) do t = t + v end return t end return sum(1, 2, 3, 4)" },
    { name = "metatable-index", code = "local o = setmetatable({}, { __index = function() return 42 end }) return o.answer" },
    { name = "string-byte", code = "local s = \"colisseum\" local n = 0 for i = 1, #s do n = n + s:byte(i) end return n" },
    { name = "boolean-logic", code = "local a, b = true, false return (a and true) or (b and 2 or 3)" },
}
local text_presets = { "easy", "medium", "hard", "full", "secure" }
for _, preset in ipairs(text_presets) do
    for _, program in ipairs(BATTERY) do
        local ok, original = run_probe(program.code)
        check(ok, program.name .. " original runs")
        local output = build(program.code, preset, 17)
        local ok2, obfuscated = run_probe(output)
        check(ok2, program.name .. " [" .. preset .. "] runs")
        local l = original[1]
        local r = obfuscated[1]
        check(type(l) == type(r) and l == r, program.name .. " [" .. preset .. "] matches")
    end
end

-- ---------------------------------------------------------------------------
-- 8. runtime-integrity: guard fires when its own expected hash is patched.
-- ---------------------------------------------------------------------------
do
    local ssource = "return 42"
    local out0 = RuntimeIntegrity.apply(ssource, { seed = 7 })
    local ok0, v0 = run_probe(out0)
    check(ok0 and v0[1] == 42, "runtime-integrity runs clean")
    local at = out0:find("_expected = ((", 1, true)
    check(at ~= nil, "runtime-integrity embeds its split expected hash")
    at = at + #"_expected = (("
    local digit = out0:sub(at, at)
    local patched = out0:sub(1, at - 1) .. tostring((tonumber(digit) + 1) % 10) .. out0:sub(at + 1)
    local okp, vp = run_probe(patched)
    check(not okp and tostring(vp):find("0x5C08", 1, true) ~= nil, "runtime-integrity fires when patched (0x5C08)")
end

-- ---------------------------------------------------------------------------
-- 9. anti-tamper: guard fires when its internal nonce digest is patched.
-- ---------------------------------------------------------------------------
do
    local ssource = "return 42"
    local out0 = AntiTamper.apply(ssource, { seed = 3 })
    local ok0, v0 = run_probe(out0)
    check(ok0 and v0[1] == 42, "anti-tamper runs clean")
    local salt = Crypto.digest(ssource .. tostring(3))
    local nonce = tostring(salt)
    local digest = Crypto.digest(nonce)
    -- The expected digest is embedded as the sum of two separately-printed
    -- addends: locate the marker the template emits and patch inside it.
    local addend2 = digest % 1000003
    local addend1 = digest - addend2
    local at = out0:find("(" .. addend1 .. ") + (" .. addend2, 1, true)
    check(at ~= nil, "anti-tamper embeds its split nonce digest")
    at = at + 1
    local digit = out0:sub(at, at)
    local patched = out0:sub(1, at - 1) .. tostring((tonumber(digit) + 1) % 10) .. out0:sub(at + 1)
    local okp, vp = run_probe(patched)
    check(not okp and tostring(vp):find("0x7A31", 1, true) ~= nil, "patched anti-tamper guard fires (0x7A31)")
end

-- ---------------------------------------------------------------------------
-- 10. ChaCha20 seal rejects a corrupted encrypted payload.
-- ---------------------------------------------------------------------------
do
    local payload = Obfuscator.compile("return 42")
    for trial = 1, 8 do
        local loader = Package.seal(payload, 100 + trial, "p")
        local probe = "local _coli_seal = " .. loader .. "\nreturn _coli_seal"
        local ok0, v0 = run_probe(probe)
        check(ok0 and v0[1] == payload, "seal round-trips encrypted bytecode (trial " .. trial .. ")")
        -- Flip a digit inside the embedded key array: decryption then fails the
        -- checksum on load and every single-bit corruption must abort with 0x3E9D.
        local start = loader:find("={", 1, true)
        local digit_pos = loader:find("%d", start)
        local digit = loader:sub(digit_pos, digit_pos)
        local patched = loader:sub(1, digit_pos - 1) .. tostring((tonumber(digit) + 1) % 10) .. loader:sub(digit_pos + 1)
        local probe2 = "local _coli_seal = " .. patched .. "\nreturn _coli_seal"
        local okp, vp = run_probe(probe2)
        check(not okp and tostring(vp):find("0x3E9D", 1, true) ~= nil, "seal rejects a corrupted payload (trial " .. trial .. ")")
    end
    check(true, "seal rejects a corrupted payload in all trials (0x3E9D)")
end

-- ---------------------------------------------------------------------------
-- 11. Fortress bundle executes on the tree-walker register VM and returns 42.
-- ---------------------------------------------------------------------------
local okf, vf = run_probe(fortress_a)
check(okf and vf[1] == 42, "fortress bundle executes on the register VM and returns 42")

print("")
print("Security evidence suite: " .. passed .. " passed, 0 failed")