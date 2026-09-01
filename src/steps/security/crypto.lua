local Step = { name = "crypto", version = 5 }

local function digest(value, seed)
    if type(value) ~= "string" then error("crypto: digest input must be a string") end
    local state = (seed or 2166136261) % 2147483647
    for index = 1, #value do
        state = (state + value:byte(index) * 16777619) % 2147483647
        state = (state * 48271) % 2147483647
    end
    return state
end

Step.digest = digest
Step.metadata = {
    id = Step.name,
    kind = "backend",
    description = "Encrypts the program as ChaCha20 Luau bytecode run by the embedded Fiu VM. No loadstring."
}

-- crypto and vm are the two names for the same authenticated, encrypted bytecode
-- backend: compile to Luau bytecode, ChaCha20-encrypt it under a masked key, and
-- run it on the embedded Fiu VM, decrypting purely with bitwise ops (no
-- loadstring). Applying both stacks a second VM layer for extra depth.
function Step.apply(source, options)
    local Vm = require("src.steps.security.vm")
    return Vm.apply(source, options)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
