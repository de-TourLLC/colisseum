local Validate = require("src.core.validate")
local Parser = require("src.core.parser")
local Ast = require("src.core.ast")
local References = require("src.core.references")
local Bytecode = require("src.core.bytecode")
local Runtime = require("src.core.runtime")
local LuauCompiler = require("src.core.luau-compiler")
local StepRegistry = require("src.core.step-registry")
local catalog = require("src.steps.catalog")
local Errors = require("src.core.errors")
local StepPaths = require("src.core.step-paths")
local Entropy = require("src.core.entropy")
local LuauTypes = require("src.core.luau-type-erase")

local Obfuscator = {}
Obfuscator.version = "0.1.0"

local targets = { lua = true, luau = true }

local presets = {
    easy = {
        { "line-ending-normalize", { } },
        { "trailing-whitespace", { } },
        { "minify", { } },
        { "rename", { } }
    },
    hard = {
        { "line-ending-normalize", { } },
        { "trailing-whitespace", { } },
        { "minify", { } },
        { "anti-deobfuscation", { maxTripwires = 4 } },
        { "garbage-code", { max_insertions = 4 } },
        { "table-noise", { max_insertions = 2 } },
        { "boolean-noise", { max_replacements = 32 } },
        { "literal-padding", { } },
        { "numbers", { } },
        { "rename", { } },
        { "strings", { } },
        { "anti-tamper", { threshold = 3, detectExecutor = true } },
        { "minify", { } },
        { "field-index", { } },
        { "junk-comments", { } }
    },
    medium = {
        { "line-ending-normalize", { } },
        { "trailing-whitespace", { } },
        { "minify", { } },
        { "literal-padding", { } },
        { "numbers", { } },
        { "rename", { } },
        { "strings", { } },
        { "anti-tamper", { threshold = 4, detectExecutor = true } },
        { "minify", { } },
        { "field-index", { } },
        { "junk-comments", { } }
    },
    full = {
        { "line-ending-normalize", { } },
        { "trailing-whitespace", { } },
        { "minify", { } },
        { "anti-deobfuscation", { maxTripwires = 8 } },
        { "garbage-code", { max_insertions = 8 } },
        { "table-noise", { max_insertions = 4 } },
        { "boolean-noise", { max_replacements = 64 } },
        { "literal-padding", { } },
        { "numbers", { } },
        { "rename", { } },
        { "strings", { } },
        { "anti-tamper", { threshold = 3, detectExecutor = true } },
        { "field-index", { } },
        { "junk-comments", { } }
    },
    total = {
        { "line-ending-normalize", { } },
        { "trailing-whitespace", { } },
        { "minify", { } },
        { "control-flow-flatten", { } },
        { "anti-deobfuscation", { maxTripwires = 12 } },
        { "garbage-code", { max_insertions = 12 } },
        { "junk-functions", { max_functions = 4 } },
        { "opaque-predicates", { max_insertions = 10 } },
        { "table-noise", { max_entries = 8 } },
        { "boolean-noise", { max_replacements = 128 } },
        { "literal-padding", { } },
        { "numbers", { } },
        { "split-strings", { } },
        { "constant-array", { } },
        { "rename", { } },
        { "authenticated-strings", { } },
        { "string-byte-encoding", { } },
        { "strings", { } },
        { "anti-tamper", { threshold = 3, detectExecutor = true, detectTiming = true } },
        { "runtime-integrity", { } },
        { "field-index", { } },
        { "junk-comments", { } },
        { "vm", { } }
    },
    -- Maximum client-side hardening, tuned to stay fast at runtime: every static
    -- layer (control flow, opaque predicates, string encryption, renaming,
    -- field indirection, anti-tamper + executor/timing detection) feeds the
    -- REGISTER VM backend, whose encrypted+permuted bytecode and mangled
    -- interpreter carry the protection while running 2-6x faster than the
    -- tree-walker. Runs on Lua and Luau/Roblox. A deobfuscator must strip every
    -- layer, then decrypt per-build bytecode, then reverse a per-build opcode
    -- permutation over a name-mangled interpreter -- the runtime stays cheap.
    fortress = {
        { "line-ending-normalize", { } },
        { "trailing-whitespace", { } },
        { "minify", { } },
        { "control-flow-flatten", { } },
        { "opaque-predicates", { max_insertions = 12 } },
        { "anti-deobfuscation", { maxTripwires = 16 } },
        { "garbage-code", { max_insertions = 10 } },
        { "junk-functions", { max_functions = 6 } },
        { "table-noise", { max_entries = 8 } },
        { "boolean-noise", { max_replacements = 160 } },
        { "literal-padding", { } },
        { "numbers", { } },
        { "split-strings", { } },
        { "constant-array", { } },
        { "rename", { } },
        { "authenticated-strings", { } },
        { "string-byte-encoding", { } },
        { "strings", { } },
        { "anti-tamper", { threshold = 3, detectExecutor = true, detectTiming = true } },
        { "runtime-integrity", { } },
        { "field-index", { } },
        { "junk-comments", { } },
        { "vm", { backend = "register" } }
    },
    secure = {
        { "line-ending-normalize", { } },
        { "trailing-whitespace", { } },
        { "minify", { } },
        { "anti-deobfuscation", { maxTripwires = 4 } },
        { "garbage-code", { max_insertions = 4 } },
        { "table-noise", { max_insertions = 2 } },
        { "boolean-noise", { max_replacements = 32 } },
        { "literal-padding", { } },
        { "numbers", { } },
        { "rename", { } },
        { "strings", { } },
        { "anti-tamper", { threshold = 3, detectExecutor = true } },
        { "minify", { } },
        { "field-index", { } },
        { "junk-comments", { } }
    }
}

local function load_step(name)
    return require(StepPaths.module(name))
end

function Obfuscator.preset(name)
    name = tostring(name):lower()
    if not presets[name] then error("unknown preset: " .. tostring(name)) end
    local result = {}
    for index, item in ipairs(presets[name]) do
        result[index] = { item[1], item[2] }
    end
    return result
end

function Obfuscator.registry()
    local registry = StepRegistry.new(catalog)
    registry:validate()
    return registry
end

function Obfuscator.obfuscate(source, options)
    if type(source) ~= "string" then error("obfuscator: source must be a string") end
    options = options or {}
    local target = tostring(options.target or (options.luau and "luau" or "lua")):lower()
    if not targets[target] then error("obfuscator: target must be 'lua' or 'luau'") end
    local pipeline = options.steps or Obfuscator.preset(options.preset or "easy")
    -- Native VM bytecode has Lua runtime semantics. Erase Luau-only type metadata
    -- before any transforms whenever the pipeline will finish in that VM.
    if target == "luau" then
        for _, item in ipairs(pipeline) do
            if (type(item) == "string" and item or item[1]) == "vm" then
                source = LuauTypes.erase(source)
                break
            end
        end
    end
    local valid, message, position = Validate.syntax(source)
    if not valid then error("obfuscator: syntax structure error at " .. position .. ": " .. message) end
    -- Per-run seed. Explicit options.seed makes a build reproducible; otherwise a
    -- fresh seed is drawn so every obfuscation differs -- distinct keys, names,
    -- injected values, and tripwires -- even for identical input.
    local run_seed = Entropy.normalize(options.seed) or Entropy.collect()
    for step_index, item in ipairs(pipeline) do
        local name = type(item) == "string" and item or item[1]
        local step = load_step(name)
        if type(step) ~= "table" or type(step.apply) ~= "function" then
            error("obfuscator: invalid step " .. tostring(name))
        end
        -- Copy the step's options so shared preset tables are never mutated, then
        -- inject a per-step sub-seed when the caller did not pin one explicitly.
        local settings = {}
        local given = type(item) == "table" and item[2] or nil
        if type(given) == "table" then
            for key, value in pairs(given) do settings[key] = value end
        end
        settings.target = target
        if settings.seed == nil then
            settings.seed = Entropy.mix(run_seed, name .. ":" .. step_index)
        end
        source = step.apply(source, settings)
        if type(source) ~= "string" then error("obfuscator: step " .. tostring(name) .. " returned non-string") end
        -- Generator steps (vm, crypto) embed their input as numeric data inside a
        -- fixed, always-valid template, so their (often very large) output does not
        -- need re-lexing. They declare `emits_valid` to skip that cost.
        if not step.emits_valid then
            local valid_step, message_step, position_step = Validate.syntax(source)
            if not valid_step then
                error("obfuscator: step " .. tostring(name) .. " produced invalid structure at " .. position_step .. ": " .. message_step)
            end
        end
    end
    return source
end

function Obfuscator.parse(source)
    local ast = Parser.parse(LuauTypes.erase(source))
    local valid, message = Ast.validate(ast)
    if not valid then error("obfuscator: invalid AST: " .. message) end
    References.analyze(ast)
    return ast
end

function Obfuscator.compile(source)
    return Bytecode.encode(Bytecode.compile(Obfuscator.parse(source)))
end

function Obfuscator.compile_luau(source, executable, options)
    return LuauCompiler.compile(source, executable, options)
end

function Obfuscator.package_luau(source, options)
    if type(source) ~= "string" then error("obfuscator: source must be a string") end
    options = options or {}
    if type(options) ~= "table" then error("obfuscator: options must be a table") end
    -- Backend: "native" (default) is Colisseum's own obfuscated VM and needs no
    -- external compiler; its one output runs on both Lua/LuaJIT and Luau/Roblox.
    -- "fiu" runs real Luau bytecode (full Luau syntax) and requires the compiler.
    local backend = options.backend or "native"
    if backend == "fiu" and (type(options.compiler) ~= "string" or options.compiler == "") then
        error("obfuscator: the Fiu backend requires a Luau compiler path")
    end
    local target = options.target or "luau"
    -- Run the preset's transforms but NOT its own `vm` step: package_luau applies
    -- the VM itself with the chosen backend, so a preset that already carries a vm
    -- step (e.g. total) must not double-package.
    local steps = {}
    for _, item in ipairs(Obfuscator.preset(options.preset or "secure")) do
        if item[1] ~= "vm" then steps[#steps + 1] = item end
    end
    if target == "luau" and backend ~= "fiu" then source = LuauTypes.erase(source) end
    local transformed = Obfuscator.obfuscate(source, {
        steps = steps,
        target = target,
        seed = options.seed
    })
    return load_step("vm").apply(transformed, {
        target = target,
        backend = backend,
        seed = options.seed,
        compiler = options.compiler,
        fiu = options.fiu,
        compiler_options = options.compiler_options
    })
end

function Obfuscator.inspect(source)
    return Runtime.inspect(Bytecode.decode(Obfuscator.compile(source)))
end

function Obfuscator.execute(source, options)
    local program = Bytecode.decode(Obfuscator.compile(source))
    return Runtime.run(program, options)
end

function Obfuscator.try(callback, ...)
    return Errors.protect(callback, ...)
end

function Obfuscator.safe(source, options)
    return Errors.protect(Obfuscator.obfuscate, source, options)
end

Obfuscator.run = Obfuscator.obfuscate
Obfuscator.presets = presets

return Obfuscator
