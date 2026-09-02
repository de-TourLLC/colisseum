local Step = { name = "native-vm", version = 2 }

Step.metadata = {
    id = Step.name,
    kind = "backend",
    description = "Compiles source to ChaCha-encrypted Colisseum bytecode run by the embedded native VM. No loadstring."
}

local function read(path)
    local file = io.open(path, "rb")
    if not file then error("native-vm: cannot read " .. path) end
    local value = file:read("*a")
    file:close()
    return value
end

-- Resolve the VM module sources relative to this file (cwd-independent).
local this = debug.getinfo(1, "S").source:sub(2)
local core_dir = (this:match("^(.*[/\\])") or "./") .. "../../core/"

-- Turn Lua source into a self-contained chunk that: embeds the native VM
-- (bytecode decoder + interpreter), carries the program as ChaCha20-encrypted
-- Colisseum bytecode, decrypts it at load with pure bitwise ops (never
-- loadstring), and runs it on the VM. This is the Lua-target analogue of the
-- Fiu/ChaCha packaging -- a real bytecode VM, no source or plaintext bytecode.
function Step.apply(source, options)
    if type(source) ~= "string" then error("native-vm: source must be a string") end
    if options ~= nil and type(options) ~= "table" then error("native-vm: options must be a table") end
    options = options or {}

    local Compiler = require("src.core.compiler")
    local Bytecode = require("src.core.bytecode")
    local Package = require("src.core.luau-package")
    local Entropy = require("src.core.entropy")
    local Minify = require("src.steps.minify")

    local seed = Entropy.normalize(options.seed) or Entropy.collect()
    local prng = Entropy.prng(tostring(seed) .. "|native-vm")

    -- Per-build marker prefix so the bundle carries no fixed scannable names.
    local prefix = "coli_"
    for _ = 1, 6 do prefix = prefix .. string.char(97 + prng:range(0, 25)) end

    -- Phase 3: per-build opcode permutation + KAT enum branding. Every build
    -- assigns the VM's opcodes different numbers -- so no two builds share a
    -- bytecode encoding and a generic decoder cannot assume "opcode 1 = chunk" --
    -- and the embedded interpreter dispatches on a KAT.<NAME> numeric enum table
    -- (lexer/VM style) instead of readable opcode strings. The opcode table and
    -- the compiled program are remapped to match.
    local program = Bytecode.decode(Compiler.compile(source))
    local by_code, opcode_count = {}, 0
    for name, code in pairs(Bytecode.opcodes()) do
        by_code[code] = name
        if code > opcode_count then opcode_count = code end
    end
    local perm = {}
    for i = 1, opcode_count do perm[i] = i end
    for i = opcode_count, 2, -1 do local j = prng:range(1, i); perm[i], perm[j] = perm[j], perm[i] end
    for _, instruction in ipairs(program.instructions) do instruction.opcode = perm[instruction.opcode] end
    -- Skip host validation: the program now carries permuted opcodes that only the
    -- embedded (equally permuted) VM validates against.
    local bytecode = Bytecode.encode(program, true)

    -- Permuted opcode -> actual name (kept for the embedded VM's shape validator
    -- and error messages) and actual name -> permuted number (for the KAT enum).
    local permuted_kinds, opnum = {}, {}
    for code = 1, opcode_count do
        permuted_kinds[perm[code]] = by_code[code]
        opnum[by_code[code]] = perm[code]
    end

    -- Rewrite the interpreter's opcode dispatch from readable string comparisons
    -- (op=="chunk") to per-build KAT enum constants (op==KAT_CHUNK). These are flat
    -- locals, so each comparison is a fast register read (a table field like
    -- KAT.CHUNK would cost a hash lookup on every branch of the dispatch chain).
    -- Only the op/cop dispatch variables and the method-receiver `.opcode` check
    -- are rebranded; type guards such as type(x)=="string" are left untouched.
    local function katify(src)
        src = src:gsub("names%[instructions%[id%]%.opcode%]", "instructions[id].opcode")
        src = src:gsub("names%[instructions%[cid%]%.opcode%]", "instructions[cid].opcode")
        src = src:gsub("names%[instructions%[callee_id%]%.opcode%]", "instructions[callee_id].opcode")
        src = src:gsub('([^%w_])(c?op)%s*==%s*"([%w]+)"', function(pre, var, nm)
            if opnum[nm] then return pre .. var .. "==KAT_" .. nm:upper() end
            return pre .. var .. '=="' .. nm .. '"'
        end)
        src = src:gsub('%.opcode%s*==%s*"([%w]+)"', function(nm)
            if opnum[nm] then return ".opcode==KAT_" .. nm:upper() end
            return '.opcode=="' .. nm .. '"'
        end)
        return src
    end

    -- KAT enum constants (per-build numbers), declared as flat locals at the top of
    -- the VM IIFE. No single nested function references more than a handful, so the
    -- LuaJIT 60-upvalue-per-function cap is not a concern.
    local kat_defs = {}
    for code = 1, opcode_count do
        kat_defs[#kat_defs + 1] = "local KAT_" .. by_code[code]:upper() .. "=" .. perm[code]
    end
    local kat_table = table.concat(kat_defs, " ") .. "\n"

    -- ChaCha20 decryptor expression -> plaintext bytecode string at runtime.
    local sealed = Package.seal(bytecode, seed, prefix .. "s")

    -- Embed the VM with its opcode table reordered to the per-build permutation
    -- and its dispatch rebranded to the KAT enum, then strip comments/whitespace
    -- so nothing readable survives and it is smaller. The bytecode module is also
    -- name-mangled and its opcode-name strings encrypted (exactly like the
    -- register backend), so the kind list no longer ships as readable plain text.
    local kinds_literal = "{\"" .. table.concat(permuted_kinds, "\",\"") .. "\"}"
    local bytecode_raw = read(core_dir .. "bytecode.lua"):gsub("local kinds = %b{}", "local kinds = " .. kinds_literal, 1)
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
    local bytecode_src = Minify.apply(harden(bytecode_raw, "natbc", true))
    local runtime_src = Minify.apply(harden(kat_table .. katify(read(core_dir .. "runtime.lua")), "natrt", false))

    local B, R, C, P, V, E = prefix .. "B", prefix .. "R", prefix .. "C", prefix .. "P", prefix .. "V", prefix .. "E"
    -- Resolve globals from the running script's own environment first
    -- (getfenv(0): the Roblox/Luau globals with print, game, task, ...), falling
    -- back to _G. This makes the one native-VM output run on both plain Lua/LuaJIT
    -- and Luau/Roblox, where host globals do not live in _G.
    local environment = "(function() local g=rawget(_G,\"getfenv\") return (type(g)==\"function\" and g(0)) or _G end)()"
    return table.concat({
        "local " .. B .. "=(function()", bytecode_src, "end)()",
        "local " .. R .. "=(function() local require=function() return " .. B .. " end", runtime_src, "end)()",
        "local " .. C .. "=" .. sealed,
        "local " .. P .. "=" .. B .. ".decode(" .. C .. ")",
        "local " .. E .. "=" .. environment,
        "local " .. V .. "=" .. R .. ".run(" .. P .. ",{environment=" .. E .. "})",
        "return " .. V .. "[1]," .. V .. "[2]," .. V .. "[3]," .. V .. "[4]",
    }, "\n")
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
