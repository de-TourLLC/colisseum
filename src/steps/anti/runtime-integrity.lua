-- runtime-integrity
--
-- Prepends a small, self-contained startup guard that verifies the runtime
-- environment has not been tampered
-- with before the original program runs. On a clean Lua 5.1 / LuaJIT / Luau
-- runtime every check is designed to pass, the guard does nothing, and the
-- original chunk executes and returns exactly as before. It only calls
-- error(..., 0) when the environment genuinely looks altered:
--
--   * a self-consistency tripwire: an embedded build nonce is re-hashed at
--     startup and compared against the expected value computed here at build
--     time (a light "was the guard itself patched?" check),
--   * core functions were swapped out (_G.type ~= type, _G.pcall ~= pcall, ...),
--   * a debug hook is actually installed (only flagged when one is present;
--     the absence of the debug library is never treated as tampering).
--
-- Every access that could be intercepted is wrapped in pcall, and every check
-- is conservative so a normal run never trips it.

local Entropy = require("src.core.entropy")

local Step = {}
Step.name = "runtime-integrity"
Step.version = 1

-- Build-time FNV-1a-style fold. This MUST mirror the hash emitted into the
-- guard below byte-for-byte so the runtime recomputation matches the value we
-- embed here. Result is an integer-valued string (<= 10 digits), which
-- tostring renders identically across Lua 5.1, LuaJIT, Lua 5.3/5.4 and Luau.
local function fold(value)
    local state = 2166136261 % 2147483647
    for index = 1, #value do
        state = (state + value:byte(index) * 16777619) % 2147483647
        state = (state * 48271) % 2147483647
    end
    return tostring(state)
end

-- The guard template. `_ri_` variable prefixes are salted per build (so two
-- builds never share identifiers) and the modulo operator is written `%%`
-- because the whole string is passed through string.format.
local TEMPLATE = [=[
do
    local _ri_type = type
    local _ri_pcall = pcall
    local _ri_error = error
    local _ri_tostring = tostring
    local _ri_global = _G
    local _ri_nonce = %q
    local _ri_expected = %q

    local function _ri_hash(_ri_value)
        local _ri_state = 2166136261 %% 2147483647
        for _ri_index = 1, #_ri_value do
            _ri_state = (_ri_state + _ri_value:byte(_ri_index) * 16777619) %% 2147483647
            _ri_state = (_ri_state * 48271) %% 2147483647
        end
        return _ri_tostring(_ri_state)
    end

    -- Self-consistency tripwire: the embedded nonce must still hash to the
    -- value baked in at build time.
    if _ri_hash(_ri_nonce) ~= _ri_expected then
        _ri_error("ᴄᴏʟɪѕѕᴇᴜᴍ ︱ Oh Noes!, An error ocurred: 0x5C08", 0)
    end

    -- Core functions must not have been replaced. The captured locals are the
    -- values the chunk's own environment resolves for these globals; they must
    -- still be identical to what _G exposes. A raw ~= nil test is used (rather
    -- than a type() call) so this stays valid even when `type` is the function
    -- being tampered with. On every clean runtime _G is a table and all four
    -- comparisons are false.
    if _ri_global ~= nil then
        if _ri_global.type ~= _ri_type then
            _ri_error("ᴄᴏʟɪѕѕᴇᴜᴍ ︱ Oh Noes!, An error ocurred: 0x5C08", 0)
        end
        if _ri_global.pcall ~= _ri_pcall then
            _ri_error("ᴄᴏʟɪѕѕᴇᴜᴍ ︱ Oh Noes!, An error ocurred: 0x5C08", 0)
        end
        if _ri_global.error ~= _ri_error then
            _ri_error("ᴄᴏʟɪѕѕᴇᴜᴍ ︱ Oh Noes!, An error ocurred: 0x5C08", 0)
        end
        if _ri_global.tostring ~= _ri_tostring then
            _ri_error("ᴄᴏʟɪѕѕᴇᴜᴍ ︱ Oh Noes!, An error ocurred: 0x5C08", 0)
        end
    end

    -- A debug hook is only flagged when one is genuinely installed. The debug
    -- library being absent (or gethook throwing) is never treated as tampering.
    local _ri_ok_dbg, _ri_debug = _ri_pcall(function() return _ri_global.debug end)
    if _ri_ok_dbg and _ri_type(_ri_debug) == "table" and _ri_type(_ri_debug.gethook) == "function" then
        local _ri_ok_hook, _ri_hook = _ri_pcall(_ri_debug.gethook)
        if _ri_ok_hook and _ri_hook ~= nil then
            _ri_error("ᴄᴏʟɪѕѕᴇᴜᴍ ︱ Oh Noes!, An error ocurred: 0x5C08", 0)
        end
    end
end
]=]

function Step.apply(source, options)
    if type(source) ~= "string" then
        error("runtime-integrity: source must be a string")
    end
    if options ~= nil and type(options) ~= "table" then
        error("runtime-integrity: options must be a table")
    end
    options = options or {}

    -- Preserve a leading shebang: the guard is inserted after it, never before.
    local shebang = source:match("^(#![^\n]*\n)")
    local body
    if shebang then
        body = source:sub(#shebang + 1)
    else
        shebang = ""
        body = source
    end

    -- Per-build PRNG. With an explicit seed it replays exactly (reproducible
    -- builds); without one it draws fresh entropy so every build differs.
    local prng = Entropy.prng(options.seed)

    -- Salt for variable-name uniqueness (alphanumeric only, always valid).
    local salt = prng:identifier(8):gsub("[^%w]", "")
    if salt == "" then salt = "s" end

    -- Nonce built from PRNG output only: contains no underscore, so the "_ri_"
    -- prefix rename below can never touch the embedded literal, and it stays
    -- deterministic for a given seed while remaining unique otherwise.
    local nonce = salt .. "." .. tostring(prng:next()) .. "." .. tostring(prng:next())
    local expected = fold(nonce)

    -- Rename the guard's local variables first (gsub leaves the %q/%% format
    -- directives untouched), then splice in the nonce and its expected hash so
    -- neither is affected by the rename.
    local prefix = "_ri" .. salt .. "_"
    local guard = TEMPLATE:gsub("_ri_", prefix):format(nonce, expected)

    return shebang .. guard .. "\n" .. body
end

setmetatable(Step, {
    __call = function(self, source, options)
        return self.apply(source, options)
    end
})

return Step
