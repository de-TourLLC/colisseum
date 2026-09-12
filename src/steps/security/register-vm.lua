local Step = { name = "register-vm", version = 2 }

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
    -- Per-build superoperators: randomly enable each fusable pair (at least one on).
    local fuse_enabled = { MM = prng:range(0, 1) == 1, LL = prng:range(0, 1) == 1, GG = prng:range(0, 1) == 1 }
    if not (fuse_enabled.MM or fuse_enabled.LL or fuse_enabled.GG) then fuse_enabled.MM = true end
    RegBytecode.fuse(mainproto, fuse_enabled)
    local opcount = RegBytecode.COUNT
    local perm = {}
    for i = 1, opcount do perm[i] = i end
    for i = opcount, 2, -1 do local j = prng:range(1, i); perm[i], perm[j] = perm[j], perm[i] end

    -- Polymorphic opcodes: give each op several interchangeable raw codes (chosen
    -- per instruction); `norm` folds them back to the permuted canonical and ships
    -- as program.o. Raw codes are one byte (total <= 255).
    local total = opcount + prng:range(0, 255 - opcount)
    local norm = {}
    local aliases_for = {}
    for c = 1, opcount do
        norm[perm[c]] = perm[c]
        aliases_for[perm[c]] = { perm[c] }
    end
    for r = opcount + 1, total do
        local pv = perm[prng:range(1, opcount)]
        norm[r] = pv
        aliases_for[pv][#aliases_for[pv] + 1] = r
    end
    local function remap(proto)
        for _, inst in ipairs(proto.code) do
            local list = aliases_for[perm[inst[1]]]
            inst[1] = list[prng:range(1, #list)]
        end
        for _, child in ipairs(proto.protos) do remap(child) end
    end
    remap(mainproto)
    local norm_parts = {}
    for k = 1, total do norm_parts[k] = norm[k] end
    local norm_literal = "{" .. table.concat(norm_parts, ",") .. "}"

    -- Opaque in-memory encoding: the program ships as a build-foged byte stream
    -- (one concatenated blob of every proto's constants + instructions) plus a
    -- numeric region map. The interpreter un-fogs each byte on demand, so no
    -- decoded {code, constants, protos} tree exists to dump (V-H1/A-1).
    report(0.4, "vm:encoding")
    local nfog = prng:range(6, 10)
    local fog = {}
    for i = 1, nfog do fog[i] = prng:range(0, 255) end
    -- Real ChaCha20 stream cipher over the blob (opt-in; default in fortress). The
    -- runtime derives the identical RFC 8439 keystream from the fog and un-masks on
    -- demand, so the decoded program still never materializes in memory.
    local enc_field = ""
    if options.encrypt then enc_field = ",enc=1" end
    -- Interpreter-bound tamper gate (opt-in; default in fortress). Decisive
    -- executor/injector marker names travel escaped (byte-by-byte, the same standard
    -- Environment uses for sensitive names -- no plaintext "getgenv" in the bundle);
    -- reg-runtime latches the silent honeypot drift if any one is present at start,
    -- so the anti-tamper response lives IN the VM, not only in the compiled payload.
    local m_field = ""
    if options.tamperVM then
        local marks = {
            "getgenv", "getrenv", "getsenv", "identifyexecutor", "getexecutorname",
            "KRNL_LOADED", "SYNAPSE_LOADED", "PROTOSMASHER_LOADED", "secure_load",
            "is_synapse_function", "syn_context_get", "is_sirhurt_closure", "fluxus", "getgc",
        }
        local esc = {}
        for i = 1, #marks do
            esc[i] = '"' .. marks[i]:gsub(".", function(c) return string.format("\\%03d", c:byte()) end) .. '"'
        end
        m_field = ",m={" .. table.concat(esc, ",") .. "}"
    end
    local blob, regs = RegBytecode.encode_opaque(mainproto, fog, options.encrypt)
    -- Optional Fibonacci (Zeckendorf) blob layer: carry the fogged byte stream as a
    -- bit-packed sequence of self-delimiting Fibonacci codewords (every numeric
    -- constant, operand, and offset in the blob is thereby re-encoded). The runtime
    -- rebuilds the exact bytes once at VM start; the hot loop is unchanged. Opt-in
    -- (options.fibonacci) since it grows the payload and adds a one-time decode.
    local fib_field = ""
    if options.fibonacci then
        local Fibonacci = require("src.core.fibonacci")
        local packed, bitlen = Fibonacci.pack_bits(Fibonacci.encode_bytes(blob))
        blob = packed
        fib_field = ",fib=" .. bitlen
    end
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
    -- A fresh modulus for every decoy, drawn from a wide range each time. The old
    -- prologue hard-coded `%9973`, which was a single grep-able signature present
    -- in every build; a per-decoy random modulus removes that fixed marker.
    local function decoy_mod()
        return tostring(noise_prng:range(257, 65521))
    end
    -- Decoy FUNCTION skeletons. Each is never called, so any of these shapes is
    -- interchangeable; picking one at random per decoy means no single function
    -- body pattern recurs across builds. All stay inside the portable subset
    -- (locals, local function, for, if/return, and/or/==/~=, + - * %, numeric
    -- literals) so the output runs on Lua 5.1/LuaJIT and Luau alike.
    local fn_shapes = {
        function() -- accumulating for-loop (random modulus)
            local name, arg, acc = decoy_ident(), decoy_ident(), decoy_ident()
            return "local function " .. name .. "(" .. arg .. ") local " .. acc ..
                "=0 for " .. decoy_ident() .. "=1," .. tostring(noise_prng:range(2, 9)) ..
                " do " .. acc .. "=(" .. acc .. "+(" .. arg .. "*" .. tostring(noise_prng:range(2, 7)) ..
                "))%" .. decoy_mod() .. " end return " .. acc .. " end"
        end,
        function() -- straight-line arithmetic over two params
            local name, x, y, r = decoy_ident(), decoy_ident(), decoy_ident(), decoy_ident()
            return "local function " .. name .. "(" .. x .. "," .. y .. ") local " .. r .. "=(" ..
                x .. "*" .. tostring(noise_prng:range(2, 13)) .. "+" .. y .. "-" .. tostring(noise_prng:range(1, 97)) ..
                ")%" .. decoy_mod() .. " return " .. r .. " end"
        end,
        function() -- branch that returns one of two folded constants
            local name, arg, m = decoy_ident(), decoy_ident(), decoy_ident()
            return "local function " .. name .. "(" .. arg .. ") local " .. m .. "=" .. arg ..
                "%" .. tostring(noise_prng:range(2, 8)) .. " if " .. m .. "==0 then return " ..
                tostring(noise_prng:range(0, 9999)) .. " end return " .. tostring(noise_prng:range(0, 9999)) .. " end"
        end,
        function() -- chained locals, returns the last
            local name, arg = decoy_ident(), decoy_ident()
            local a, b = decoy_ident(), decoy_ident()
            return "local function " .. name .. "(" .. arg .. ") local " .. a .. "=" .. arg .. "+" ..
                tostring(noise_prng:range(1, 999)) .. " local " .. b .. "=(" .. a .. "*" ..
                tostring(noise_prng:range(2, 9)) .. ")%" .. decoy_mod() .. " return " .. b .. " end"
        end,
    }
    -- Always-FALSE predicate skeletons guarding a dead block. Each construction is
    -- provably false at runtime (so the guarded body never runs and control always
    -- flows on) but reaches that falsity a different way, so the guard is not one
    -- recurring `a==b and lit==lit+k` shape.
    local pred_shapes = {
        function() -- (a==b) and (base ~= base): identity contradiction
            local a, b = decoy_ident(), decoy_ident()
            local lit = tostring(noise_prng:range(2, 9000))
            local base = noise_prng:range(2, 9000)
            return "local " .. a .. "," .. b .. "=" .. lit .. "," .. lit ..
                " if " .. a .. "==" .. b .. " and " .. tostring(base) .. "==" .. tostring(base + noise_prng:range(1, 3)) ..
                " then return " .. decoy_ident() .. "," .. decoy_ident() .. " end " ..
                decoy_ident() .. "=" .. tostring(noise_prng:range(1, 3))
        end,
        function() -- x ~= x is false for any non-NaN number
            local x = decoy_ident()
            return "local " .. x .. "=" .. tostring(noise_prng:range(2, 9000)) ..
                " if " .. x .. "~=" .. x .. " then return " .. decoy_ident() .. " end " ..
                decoy_ident() .. "=" .. tostring(noise_prng:range(1, 3))
        end,
        function() -- lo > hi with lo < hi chosen: strict-order contradiction
            local lo = noise_prng:range(1, 4000)
            local hi = lo + noise_prng:range(1, 4000)
            local p, q = decoy_ident(), decoy_ident()
            return "local " .. p .. "," .. q .. "=" .. tostring(lo) .. "," .. tostring(hi) ..
                " if " .. p .. ">" .. q .. " then return " .. decoy_ident() .. " end " ..
                decoy_ident() .. "=" .. tostring(noise_prng:range(1, 3))
        end,
        function() -- (n*0) ~= 0 is always false
            local n = decoy_ident()
            return "local " .. n .. "=" .. tostring(noise_prng:range(2, 9000)) ..
                " if (" .. n .. "*0)~=0 then return " .. decoy_ident() .. " end " ..
                decoy_ident() .. "=" .. tostring(noise_prng:range(1, 3))
        end,
    }
    -- "Fake stage" skeletons: compute and discard throwaway values.
    local stage_shapes = {
        function()
            local sink, stage = decoy_ident(), decoy_ident()
            return "local " .. sink .. "=" .. tostring(noise_prng:range(0, 50)) ..
                " local " .. stage .. "=" .. tostring(noise_prng:range(2, 7)) ..
                " for " .. decoy_ident() .. "=1," .. tostring(noise_prng:range(3, 12)) ..
                " do " .. sink .. "=(" .. sink .. "*" .. stage .. ")%" .. decoy_mod() ..
                " end " .. sink .. "=" .. sink .. "*0"
        end,
        function()
            local sink = decoy_ident()
            return "local " .. sink .. "=" .. tostring(noise_prng:range(1, 9999)) ..
                " " .. sink .. "=(" .. sink .. "+" .. tostring(noise_prng:range(1, 9999)) ..
                ")%" .. decoy_mod() .. " " .. sink .. "=" .. sink .. "-" .. sink
        end,
    }
    local function noise_blocks()
        -- Build a mixed pool of decoys, then shuffle so the emission order is not a
        -- fixed functions->predicates->stages sequence. Both the *shapes* (above)
        -- and their *order* now vary per build, so a scanner cannot key on either
        -- a recurring body pattern or a recurring block layout. Returns the list so
        -- the caller can interleave the decoys among the real VM setup statements
        -- (rather than emit them as one contiguous, strippable prologue block).
        local pool = {}
        for _ = 1, noise_prng:range(2, 4) do pool[#pool + 1] = noise_prng:pick(fn_shapes)() end
        for _ = 1, noise_prng:range(2, 4) do pool[#pool + 1] = noise_prng:pick(pred_shapes)() end
        for _ = 1, noise_prng:range(1, 2) do pool[#pool + 1] = noise_prng:pick(stage_shapes)() end
        for ii = #pool, 2, -1 do
            local jj = noise_prng:range(1, ii)
            pool[ii], pool[jj] = pool[jj], pool[ii]
        end
        return pool
    end

    report(0.92, "vm:finishing")
    local Environment = require("src.steps.security.environment")
    local R, S, F, G, E, A, V, O = prefix .. "R", prefix .. "S", prefix .. "F", prefix .. "G", prefix .. "E", prefix .. "A", prefix .. "V", prefix .. "O"
    -- Layout: the VM interpreter comes FIRST -- the bundle opens with the runtime
    -- itself, not a decoy prologue, so a deobfuscator cannot treat a leading junk
    -- block as "skip to the real code" and lift the VM out. The payload/env locals
    -- and the decoy noise are all independent statements that only have to precede
    -- the run; they are shuffled together so the VM setup is not one contiguous,
    -- liftable region framed by strippable junk. Lua requires the chunk's `return`
    -- to be last, so the run + return stay at the tail.
    local head = "local " .. R .. "=(function()\n" .. runtime_src .. "\nend)()"
    local mids = {
        "local " .. S .. "=" .. blob_literal,
        "local " .. F .. "=" .. fog_literal,
        "local " .. G .. "=" .. regs_literal,
        "local " .. O .. "=" .. norm_literal,
        "local " .. E .. "=" .. Environment.expression(),
        "local " .. A .. "=" .. Environment.anchor(),
    }
    -- Decoy VM routes ("false paths"): each is a self-contained block of payload-
    -- shaped locals (a random blob string + fog/region/norm that look like the real
    -- ones) plus a dead branch, guarded by a provably-false predicate, that pcall-
    -- wraps a decoy R.run over them. A deobfuscator now sees SEVERAL `.run` calls and
    -- SEVERAL payload blobs and must analyse each to decide which one is real -- yet
    -- runtime cost is zero (the guard never passes, and the call is pcall-wrapped
    -- even if analysis forces it). This adds analysis routes without adding runtime.
    do
        -- Decoy error codes: these NEVER fire (their branches are provably dead), but
        -- a deobfuscator reading the bundle sees many branded aborts with distinct
        -- codes that look like live integrity failures, indistinguishable from the
        -- real guards. Non-injective and per-build shuffled, so they add no signal.
        local decoy_codes = {
            "8F2A", "4C71", "9D05", "B3E8", "2F19", "6A44", "0E7C", "C1B2",
            "53AF", "1A6D", "E409", "7B3C", "A0F5", "36D8", "D71E", "4820",
        }
        -- Same branded prefix the real guards use, so decoy aborts are byte-identical.
        local brand = "ᴄᴏʟɪѕѕᴇᴜᴍ ︱ Oh Noes!, An error ocurred: 0x"
        local function decoy_blob()
            local n = noise_prng:range(220, 560)
            local bytes = {}
            for i = 1, n do bytes[i] = string.format("\\%03d", noise_prng:range(0, 255)) end
            return '"' .. table.concat(bytes) .. '"'
        end
        -- A plausible-but-fake region map, shaped like a real one so a decoy cannot
        -- be told apart by a fixed `c=0,d=1` fingerprint. Never executed.
        local function decoy_regions()
            local offs = {}
            for i = 1, noise_prng:range(0, 4) do offs[i] = tostring(noise_prng:range(1, 400)) end
            return "{[0]={n=" .. noise_prng:range(0, 3) .. ",v=" .. noise_prng:range(0, 1) ..
                ",k=" .. noise_prng:range(0, 8) .. ",c=" .. noise_prng:range(4, 48) ..
                ",d=" .. noise_prng:range(1, 60) .. ",o={" .. table.concat(offs, ",") ..
                "},p={},u={}}}"
        end
        for _ = 1, noise_prng:range(2, 4) do
            local ds, df = decoy_ident(), decoy_ident()
            local dg, don, ck = decoy_ident(), decoy_ident(), decoy_ident()
            local guard = noise_prng:range(2, 9000)
            local code = noise_prng:pick(decoy_codes)
            local mod = tostring(noise_prng:range(2147483629, 2147483647))
            local seed0 = tostring(noise_prng:range(1, 2147483646))
            local expect = tostring(noise_prng:range(1, 2147483646))
            local fogn = {}
            for i = 1, noise_prng:range(4, 8) do fogn[i] = tostring(noise_prng:range(0, 255)) end
            -- A decoy integrity route: a per-build checksum function, a comparison
            -- that "verifies" the decoy blob against a baked digest and aborts with a
            -- branded code, then a decoy VM run -- all inside a provably-false guard,
            -- so it is inert (and the run is pcall-wrapped even if analysis forces it).
            mids[#mids + 1] =
                "local " .. ds .. "=" .. decoy_blob() ..
                " local " .. df .. "={" .. table.concat(fogn, ",") .. "}" ..
                " local " .. dg .. "=" .. decoy_regions() ..
                " local " .. don .. "={}" ..
                " local function " .. ck .. "(_s) local _h=" .. seed0 ..
                " for _q=1,#_s do _h=(_h*31+_s:byte(_q))%" .. mod .. " end return _h end" ..
                " if (" .. tostring(guard) .. "*0)~=0 then" ..
                " if " .. ck .. "(" .. ds .. ")~=" .. expect ..
                ' then error("' .. brand .. code .. '",0) end' ..
                " local " .. decoy_ident() .. "=pcall(function() return " .. R ..
                ".run({S=" .. ds .. ",f=" .. df .. ",r=" .. dg .. ",o=" .. don .. "},{}) end) end"
        end
    end
    for _, decoy in ipairs(noise_blocks()) do mids[#mids + 1] = decoy end
    for i = #mids, 2, -1 do local j = noise_prng:range(1, i); mids[i], mids[j] = mids[j], mids[i] end
    -- yield_interval: on Roblox, breathe (task.wait) every ~1M VM instructions when
    -- it is safe to yield, so heavy synchronous loops do not hit the execution-time
    -- limit. No-op where no scheduler exists.
    local run_stmt = "local " .. V .. "=" .. R .. ".run({S=" .. S .. ",f=" .. F .. ",r=" .. G ..
        ",o=" .. O .. fib_field .. enc_field .. m_field .. "},{environment=" .. E .. ",anchor=" .. A .. ",yield_interval=1000000})"
    local bundle = table.concat({
        head,
        table.concat(mids, "\n"),
        run_stmt,
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
