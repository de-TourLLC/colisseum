local Step = { name = "register-vm", version = 1 }

Step.metadata = {
    id = Step.name,
    kind = "backend",
    description = "Compiles source to an opaque, build-foged register bytecode blob run by the embedded register VM (faster than the tree-walker; Lua + Luau, no loadstring, no plaintext bytecode in memory)."
}

local function read(path)
    local file = io.open(path, "rb")
    if not file then error("register-vm: cannot read " .. path) end
    local value = file:read("*a")
    file:close()
    return value
end

local this = debug.getinfo(1, "S").source:sub(2)
local core_dir = (this:match("^(.*[/\\])") or "./") .. "../../core/"

-- Turn Lua source into a self-contained chunk that embeds the register VM
-- (fog-untangler + interpreter), carries the program as an opaque build-foged
-- byte stream plus a numeric region map (no plaintext bytecode ever materializes),
-- and runs it. Faster analogue of the native tree-walking backend. Runs on both
-- Lua/LuaJIT and Luau/Roblox (portable bit32/bit and getfenv(0)/_G resolution).
function Step.apply(source, options)
    if type(source) ~= "string" then error("register-vm: source must be a string") end
    if options ~= nil and type(options) ~= "table" then error("register-vm: options must be a table") end
    options = options or {}

    local RegCompiler = require("src.core.reg-compiler")
    local RegBytecode = require("src.core.reg-bytecode")
    local Package = require("src.core.luau-package")
    local Entropy = require("src.core.entropy")
    local Minify = require("src.steps.minify")

    local seed = Entropy.normalize(options.seed) or Entropy.collect()
    local prng = Entropy.prng(tostring(seed) .. "|register-vm")

    -- Per-build marker prefix so the bundle carries no fixed scannable names.
    local prefix = "coli_"
    for _ = 1, 6 do prefix = prefix .. string.char(97 + prng:range(0, 25)) end

    -- Per-build opcode permutation: shuffle the VM's opcode numbers, remap the
    -- compiled program to match, and inline the permuted numbers into the runtime
    -- dispatch -- so no two builds share an encoding and neither the packed byte
    -- stream nor the interpreter carries readable opcode names.
    local report = type(options.progress) == "function" and options.progress or function() end
    report(0.0, "vm:compiling")
    local mainproto = RegCompiler.compile(source)
    local opcount = RegBytecode.COUNT
    local perm = {}
    for i = 1, opcount do perm[i] = i end
    for i = opcount, 2, -1 do local j = prng:range(1, i); perm[i], perm[j] = perm[j], perm[i] end
    local function remap(proto)
        for _, inst in ipairs(proto.code) do inst[1] = perm[inst[1]] end
        for _, child in ipairs(proto.protos) do remap(child) end
    end
    remap(mainproto)

    -- Opaque in-memory encoding: the program ships as a build-foged byte stream
    -- (one concatenated blob of every proto's constants + instructions) plus a
    -- numeric region map. The interpreter un-fogs each byte on demand, so no
    -- decoded {code, constants, protos} tree exists to dump (V-H1/A-1).
    report(0.4, "vm:encoding")
    local nfog = prng:range(6, 10)
    local fog = {}
    for i = 1, nfog do fog[i] = prng:range(0, 255) end
    local blob, regs = RegBytecode.encode_opaque(mainproto, fog)
    local fog_literal = "{" .. table.concat(fog, ",") .. "}"
    local blob_literal = '"' .. blob:gsub(".", function(c) return string.format("\\%03d", c:byte()) end) .. '"'
    local regs_parts, max_id = {}, 0
    for id in pairs(regs) do if id > max_id then max_id = id end end
    for id = 0, max_id do
        local m = regs[id]
        local ups = {}
        for i = 1, #m.u do ups[i] = "{" .. m.u[i][1] .. "," .. m.u[i][2] .. "}" end
        regs_parts[#regs_parts + 1] = "[" .. id .. "]={n=" .. m.n .. ",v=" .. m.v ..
            ",k=" .. m.k .. ",c=" .. m.c .. ",d=" .. m.d ..
            ",o={" .. table.concat(m.o, ",") .. "},p={" .. table.concat(m.p, ",") .. "}" ..
            ",u={" .. table.concat(ups, ",") .. "}}"
    end
    local regs_literal = "{" .. table.concat(regs_parts, ",") .. "}"

    -- Embed the interpreter with its dispatch inlined to the permuted numbers:
    -- the OP table and its readable field names (MOVE, LOADK, ...) never ship --
    -- every `OP.<NAME>` token becomes a plain number, and the RegBytecode
    -- dependency line is dropped (the runtime is self-contained at that point).
    report(0.68, "vm:mangling")
    local opcode_of = RegBytecode.opcodes()
    local rt_raw = read(core_dir .. "reg-runtime.lua")
        :gsub("local RegBytecode = require%b()", "", 1)
        :gsub("local OP = RegBytecode%.OP", "local OP = {}", 1)
        :gsub("OP%.([A-Z_]+)", function(nm)
            local c = opcode_of[nm]; return c and tostring(perm[c]) or nil
        end)
    -- Obfuscate the interpreter SOURCE itself (fast: small source, payload not yet
    -- attached). rename mangles identifiers everywhere. String encryption is NOT
    -- applied to the interpreter: its strings sit outside the hot dispatch loop,
    -- and the opcode names are already gone. Each pass is guarded: a failure just
    -- keeps the previous source.
    local Rename = require("src.steps.naming.rename")
    local StepPaths = require("src.core.step-paths")
    local SplitStrings = require(StepPaths.module("split-strings"))
    local ConstantArray = require(StepPaths.module("constant-array"))
    local function harden(src, salt, encrypt_strings)
        local seed0 = Package.digest(salt .. "|" .. tostring(seed))
        local function pass(fn) local ok, out = pcall(fn); if ok and type(out) == "string" and #out > 0 then src = out end end
        pass(function() return Rename.apply(src, { seed = seed0 }) end)
        if encrypt_strings then
            pass(function() return SplitStrings.apply(src, { seed = seed0, target = "luau" }) end)
            pass(function() return ConstantArray.apply(src, { seed = seed0, target = "luau" }) end)
        end
        return src
    end
    local runtime_src = Minify.apply(harden(rt_raw, "regrt", false))

    -- Post-VM noise round. Wraps the finished bundle (which is already the sealed,
    -- encrypted register VM) in a second layer of semantic junk: decoy functions,
    -- always-false opaque predicates guarding dead blocks, and meaningless "stages"
    -- that compute and discard throwaway values. A static deobfuscator that has
    -- just unwound the VM now finds a fresh pile of garbage whose statements
    -- assemble into nothing, yet the emitted program still runs and returns
    -- exactly V[1..4] unchanged. Drawn from its own sub-seed so the noise is
    -- per-build but deterministic under an explicit seed. Only constructs the
    -- tree-walker register VM supports are used (locals, local function, for,
    -- if/then/return/end, and/or/==/~=, + - * %, numeric literals, [] indexing),
    -- and no builtins are called on the correctness-critical path.
    local noise_prng = Entropy.prng(tostring(seed) .. "|postvm")
    local function decoy_ident()
        return prefix .. noise_prng:identifier(noise_prng:range(4, 8))
    end
    local function noise_prologue()
        local out = {}
        -- 2-4 meaningless decoy functions that are never called.
        local nfun = noise_prng:range(2, 4)
        for i = 1, nfun do
            local name = decoy_ident()
            local arg = decoy_ident()
            local acc = decoy_ident()
            out[#out + 1] = "local function " .. name .. "(" .. arg .. ") local " .. acc ..
                "=0 for " .. decoy_ident() .. "=1," .. tostring(noise_prng:range(2, 9)) ..
                " do " .. acc .. "=(" .. acc .. "+(" .. arg .. "*" .. tostring(noise_prng:range(2, 7)) ..
                "))%9973 end return " .. acc .. " end"
        end
        -- 2-4 opaque always-false predicates guarding dead blocks. The predicates
        -- are (a==b) and (lit ~= lit+k): the first is true, the second false, so
        -- the guarded `return` is unreachable and execution always flows on.
        local npred = noise_prng:range(2, 4)
        for i = 1, npred do
            local a, b = decoy_ident(), decoy_ident()
            local lit = tostring(noise_prng:range(2, 9000))
            local keep = tostring(noise_prng:range(1, 3))
            local base = noise_prng:range(2, 9000)
            out[#out + 1] = "local " .. a .. "," .. b .. "=" .. lit .. "," .. lit ..
                " if " .. a .. "==" .. b .. " and " .. tostring(base) .. "==" .. tostring(base + noise_prng:range(1, 3)) ..
                " then return " .. decoy_ident() .. "," ..
                decoy_ident() .. " end " .. decoy_ident() .. "=" .. keep
        end
        -- 1-2 "fake stages" that fold plain constants but discard every result.
        local nstage = noise_prng:range(1, 2)
        for i = 1, nstage do
            local sink = decoy_ident()
            local stage = decoy_ident()
            out[#out + 1] = "local " .. sink .. "=" .. tostring(noise_prng:range(0, 50)) ..
                " local " .. stage .. "=" .. tostring(noise_prng:range(2, 7)) ..
                " for " .. decoy_ident() .. "=1," .. tostring(noise_prng:range(3, 12)) ..
                " do " .. sink .. "=(" .. sink .. "*" .. stage .. ")%" .. tostring(noise_prng:range(101, 997)) ..
                " end " .. sink .. "=" .. sink .. "*0"
        end
        return table.concat(out, " ")
    end

    report(0.92, "vm:finishing")
    local Environment = require("src.steps.security.environment")
    local R, S, F, G, E, A, V = prefix .. "R", prefix .. "S", prefix .. "F", prefix .. "G", prefix .. "E", prefix .. "A", prefix .. "V"
    local bundle = table.concat({
        noise_prologue(),
        "local " .. R .. "=(function()", runtime_src, "end)()",
        "local " .. S .. "=" .. blob_literal,
        "local " .. F .. "=" .. fog_literal,
        "local " .. G .. "=" .. regs_literal,
        "local " .. E .. "=" .. Environment.expression(),
        "local " .. A .. "=" .. Environment.anchor(),
        -- yield_interval: on Roblox, breathe (task.wait) every ~1M VM instructions
        -- when it is safe to yield, so heavy synchronous loops do not hit the
        -- execution-time limit. No-op where no scheduler exists.
        "local " .. V .. "=" .. R .. ".run({S=" .. S .. ",f=" .. F .. ",r=" .. G .. "},{environment=" .. E .. ",anchor=" .. A .. ",yield_interval=1000000})",
        "return " .. V .. "[1]," .. V .. "[2]," .. V .. "[3]," .. V .. "[4]",
    }, "\n")
    -- Collapse to a single line. The only newlines are statement separators; the
    -- minified VM source and the packed payload literals carry no literal
    -- newlines, so replacing newlines with spaces is safe and avoids re-lexing
    -- the whole (large) bundle.
    return (bundle:gsub("[\r\n]+", " "))
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
