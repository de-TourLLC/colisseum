local Step = { name = "vm", version = 4 }

-- the backends embed input as encrypted numeric data in a fixed, always-valid template,
-- so the output never needs re-lexing (full-parse validation of the bundle is skipped)
Step.emits_valid = true

Step.metadata = {
    id = Step.name,
    kind = "backend",
    description = "Compiles source to Luau bytecode, encrypts it (ChaCha20), and runs it through the embedded Fiu VM. No loadstring."
}

-- locate the bundled Luau compiler (tools/build-luau.bat) relative to cwd (the repo root via cli.lua)
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

--[[ package `source` into a self-contained chunk: embeds the Fiu Luau VM, carries the
     program as ChaCha20-encrypted bytecode, decrypts+verifies with bitwise ops (no
     loadstring), runs it. ]]
function Step.apply(source, options)
    if type(source) ~= "string" then error("vm: source must be a string") end
    if options ~= nil and type(options) ~= "table" then error("vm: options must be a table") end
    options = options or {}
    -- default backend is the native bytecode VM (portable Lua + Luau/Roblox)
    if options.backend == "register" then
        return require("src.steps.security.register-vm").apply(source, options)
    end
    if options.backend == "fiu" then
        error("vm: the Fiu backend has been retired; Colisseum runs on its own VM (use the register or native backend)")
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
