local Step = { name = "register-vm", version = 1 }

Step.metadata = {
    id = Step.name,
    kind = "backend",
    description = "Compiles source to ChaCha-encrypted register bytecode run by the embedded register VM (faster than the tree-walker; Lua + Luau, no loadstring)."
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
-- (bytecode decoder + interpreter), carries the program as ChaCha20-encrypted
-- register bytecode, decrypts it with pure bitwise ops (never loadstring), and
-- runs it. Faster analogue of the native tree-walking backend. Runs on both
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
    -- compiled program to match, and reorder the embedded opcode table, so no two
    -- builds share an encoding and a generic decoder cannot assume "opcode 1 = MOVE".
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

    report(0.4, "vm:encoding")
    local bytecode = RegBytecode.encode(mainproto)

    -- ChaCha20 decryptor expression -> plaintext register bytecode string.
    report(0.5, "vm:encrypting")
    local sealed = Package.seal(bytecode, seed, prefix .. "s")

    -- Embed the VM with its opcode table permuted to match. reg-bytecode holds the
    -- `names` list the interpreter caches opcode ids from; reorder it so OP.<X>
    -- yields the per-build number and the dispatch (op == <X>) stays consistent.
    report(0.68, "vm:mangling")
    local permuted_names = {}
    for code = 1, opcount do permuted_names[perm[code]] = RegBytecode.NAME[code] end
    local names_literal = "{\"" .. table.concat(permuted_names, "\",\"") .. "\"}"
    local bc_raw = read(core_dir .. "reg-bytecode.lua"):gsub("local names = %b{}", "local names = " .. names_literal, 1)
    -- Mangle the embedded interpreter's own identifiers (execute_proto, R, K, the
    -- opcode locals, ...) so it does not ship as a readable register VM. Only the
    -- module's local names change; the .OP/.NAME/.decode field interface between
    -- the two embedded modules is preserved (rename never touches table keys).
    -- Guarded: a rename failure just ships the (still minified) unrenamed source.
    local Rename = require("src.steps.naming.rename")
    local function harden(src, salt)
        local ok, out = pcall(function() return Rename.apply(src, { seed = Package.digest(salt .. "|" .. tostring(seed)) }) end)
        if ok and type(out) == "string" and #out > 0 then return out end
        return src
    end
    local bytecode_src = Minify.apply(harden(bc_raw, "regbc"))
    local runtime_src = Minify.apply(harden(read(core_dir .. "reg-runtime.lua"), "regrt"))

    report(0.92, "vm:finishing")
    local B, R, C, P, V, E = prefix .. "B", prefix .. "R", prefix .. "C", prefix .. "P", prefix .. "V", prefix .. "E"
    local environment = "(function() local g=rawget(_G,\"getfenv\") return (type(g)==\"function\" and g(0)) or _G end)()"
    local bundle = table.concat({
        "local " .. B .. "=(function()", bytecode_src, "end)()",
        "local " .. R .. "=(function() local require=function() return " .. B .. " end", runtime_src, "end)()",
        "local " .. C .. "=" .. sealed,
        "local " .. P .. "=" .. B .. ".decode(" .. C .. ")",
        "local " .. E .. "=" .. environment,
        -- yield_interval: on Roblox, breathe (task.wait) every ~1M VM instructions
        -- when it is safe to yield, so heavy synchronous loops do not hit the
        -- execution-time limit. No-op where no scheduler exists.
        "local " .. V .. "=" .. R .. ".run(" .. P .. ",{environment=" .. E .. ",yield_interval=1000000})",
        "return " .. V .. "[1]," .. V .. "[2]," .. V .. "[3]," .. V .. "[4]",
    }, "\n")
    -- Collapse to a single line. The only newlines are statement separators (the
    -- ChaCha loader template); the minified VM sources and the encrypted payload
    -- carry no literal newlines, so replacing newlines with spaces is safe and
    -- avoids re-lexing the whole (large) bundle.
    return (bundle:gsub("[\r\n]+", " "))
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
