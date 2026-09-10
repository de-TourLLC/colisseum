local Step = { name = "vm", version = 4 }

-- The VM backends embed their input as encrypted numeric data inside a fixed,
-- always-valid chunk template, so the (large) output never needs re-lexing. This
-- skips an expensive full-parse validation of the final bundle in the pipeline.
Step.emits_valid = true

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

-- Package `source` into a self-contained chunk: embeds the Fiu Luau VM, carries
-- the program as ChaCha20-encrypted Luau bytecode, decrypts+verifies with bitwise
-- ops (no loadstring), runs it. Source never ships as text or plaintext bytecode.
function Step.apply(source, options)
    if type(source) ~= "string" then error("vm: source must be a string") end
    if options ~= nil and type(options) ~= "table" then error("vm: options must be a table") end
    options = options or {}
    -- Default backend: the native bytecode VM (portable Lua + Luau/Roblox). The Fiu
    -- backend (options.backend == "fiu") runs real Luau bytecode for full Luau
    -- syntax, but needs the Luau compiler and ships readable interpreter source.
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
