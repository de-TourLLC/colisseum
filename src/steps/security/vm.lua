local Step = { name = "vm", version = 4 }

Step.metadata = {
    id = Step.name,
    kind = "backend",
    description = "Compiles source to Luau bytecode, encrypts it (ChaCha20), and runs it through the embedded Fiu VM. No loadstring."
}

-- Locate the bundled Luau bytecode compiler (built from vendor/Luau by
-- tools/build-luau.bat). Resolved relative to the working directory, which is the
-- repository root when invoked through cli.lua.
local function bundled_compiler()
    local suffix = package.config:sub(1, 1) == "\\" and ".exe" or ""
    local candidates = {
        "build/luau/Release/luau-compile" .. suffix,
        "build/luau/luau-compile" .. suffix,
        "bin/luau-compile" .. suffix,
        "luau-compile" .. suffix,
    }
    for _, candidate in ipairs(candidates) do
        local file = io.open(candidate, "rb")
        if file then file:close(); return candidate end
    end
    return nil
end

-- Turn `source` into a self-contained chunk that: embeds the Fiu Luau VM, carries
-- the program as ChaCha20-encrypted Luau bytecode, decrypts it at load with pure
-- bitwise ops (never loadstring), verifies its integrity, and executes it on the
-- VM. This is a real bytecode-VM backend in the spirit of Prometheus/Hercules --
-- the source never exists as text or as plaintext bytecode in the output.
function Step.apply(source, options)
    if type(source) ~= "string" then error("vm: source must be a string") end
    if options ~= nil and type(options) ~= "table" then error("vm: options must be a table") end
    options = options or {}
    -- Backend selection. Default (both Lua AND Luau/Roblox targets): Colisseum's
    -- own native bytecode VM. It is fully obfuscated -- per-build opcode
    -- permutation + KAT enum dispatch, ChaCha20-encrypted bytecode, no readable
    -- interpreter -- and its single output runs on plain Lua/LuaJIT and on
    -- Luau/Roblox alike (portable bit32/bit and getfenv(0)/_G resolution).
    --
    -- The Fiu backend (opt-in: options.backend == "fiu") runs real Luau bytecode,
    -- so it supports the full Luau syntax the native parser does not (continue,
    -- type annotations, string interpolation, if-expressions), but it ships the
    -- interpreter as (minified) readable source and needs the Luau compiler.
    if options.backend == "register" then
        return require("src.steps.security.register-vm").apply(source, options)
    end
    if options.backend ~= "fiu" then
        return require("src.steps.security.native-vm").apply(source, options)
    end
    local compiler = options.compiler
    if type(compiler) ~= "string" or compiler == "" then compiler = bundled_compiler() end
    if not compiler then
        error("vm: Luau compiler not found. Build it once with tools\\build-luau.bat " ..
            "(produces build/luau/Release/luau-compile.exe), or pass --compiler <path>.")
    end
    local Package = require("src.core.luau-package")
    local packaged, message = Package.from_source(source, compiler, options.fiu, {
        roblox = options.roblox,
        seed = options.seed,
        arguments = options.compiler_arguments,
    })
    if not packaged then error(message) end
    return packaged
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
