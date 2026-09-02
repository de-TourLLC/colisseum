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
-- embed here. Returns an integer (< 2^31) so the guarded sum adds exactly.
local function fold(value)
    local state = 2166136261 % 2147483647
    for index = 1, #value do
        state = (state + value:byte(index) * 16777619) % 2147483647
        state = (state * 48271) % 2147483647
    end
    return state
end

-- Second, independent fold (seeded multiply-accumulate) emitted into the guard
-- as _ri_hash2. Different recurrence, per-build seed: recomputing the guard's
-- expected value requires replicating BOTH folds and the seed.
local function fold2(value, seed)
    local state = seed % 2147483647
    for index = 1, #value do
        state = (state * 31 + value:byte(index)) % 2147483647
    end
    return state
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
    -- Tripwire constants are never single literals: the nonce is two
    -- concatenated string pieces and the expected digest is the sum of two
    -- separately-embedded addends. Repairing the guard means recomputing BOTH
    -- independent folds and reproducing the exact split.
    local _ri_nonce = %q .. %q
    local _ri_seed = %d
    local _ri_expected = ((%d) + (%d))

    local function _ri_hash(_ri_value)
        local _ri_state = 2166136261 %% 2147483647
        for _ri_index = 1, #_ri_value do
            _ri_state = (_ri_state + _ri_value:byte(_ri_index) * 16777619) %% 2147483647
            _ri_state = (_ri_state * 48271) %% 2147483647
        end
        return _ri_state
    end

    -- Second, independent folded digest over the same nonce, seeded per build.
    -- Touching the seed, the nonce, or the expected sum surfaces a mismatch.
    local function _ri_hash2(_ri_value)
        local _ri_state = _ri_seed %% 2147483647
        for _ri_index = 1, #_ri_value do
            _ri_state = (_ri_state * 31 + _ri_value:byte(_ri_index)) %% 2147483647
        end
        return _ri_state
    end

    -- Self-consistency tripwire: the embedded nonce must still hash, under
    -- both independent folds, to the value baked in at build time.
    if _ri_hash(_ri_nonce) + _ri_hash2(_ri_nonce) ~= _ri_expected then
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
    -- Tripwire values. The nonce is split into two concatenated string pieces
    -- and the combined expected digest is a sum of two addends, so neither
    -- constant exists as one editable literal in the output.
    local seed2 = (fold(salt .. "|ri-seed|") % 2147483646) + 1
    local expected = fold(nonce) + fold2(nonce, seed2)
    local cut = math.floor(#nonce / 2)
    local nonce_piece_1 = nonce:sub(1, cut)
    local nonce_piece_2 = nonce:sub(cut + 1)
    local expected_piece_2 = expected % 1000003
    local expected_piece_1 = expected - expected_piece_2

    -- Rename the guard's local variables first (gsub leaves the %q/%d format
    -- directives untouched), then splice in the nonce pieces, fold seed and
    -- expected addends so none are affected by the rename.
    local prefix = "_ri" .. salt .. "_"
    local guard = TEMPLATE:gsub("_ri_", prefix):format(
        nonce_piece_1, nonce_piece_2, seed2, expected_piece_1, expected_piece_2)

    return shebang .. guard .. "\n" .. body
end

setmetatable(Step, {
    __call = function(self, source, options)
        return self.apply(source, options)
    end
})

return Step
