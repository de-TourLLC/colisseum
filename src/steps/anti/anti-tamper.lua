local Step = {}
local build_counter = 0
local Crypto = require("src.steps.security.crypto")

Step.name = "anti-tamper"
Step.version = 4

local function boolean_option(options, name, default)
    local value = options[name]
    if value == nil then
        return default
    end
    return value == true
end

local function number_option(options, name, default)
    local value = tonumber(options[name])
    if value == nil or value < 1 then
        return default
    end
    return math.floor(value)
end

local function make_guard(options, tag, token, digest)
    local threshold = number_option(options, "threshold", 3)
    local mode = options.mode or "error"
    if mode ~= "error" and mode ~= "return" and mode ~= "callback" then
        error("anti-tamper: mode must be 'error', 'return', or 'callback'")
    end

    local allow_hooks = boolean_option(options, "allowHooks", false)
    local detect_executor = boolean_option(options, "detectExecutor", true)
    local detect_globals = boolean_option(options, "detectGlobals", true)
    local detect_debug = boolean_option(options, "detectDebug", true)
    local detect_loaders = boolean_option(options, "detectLoaders", true)
    local detect_metatable = boolean_option(options, "detectMetatable", true)
    local detect_timing = boolean_option(options, "detectTiming", false)

    -- Split the tripwire constants so no single literal equals the nonce or the
    -- digest (see the guard template).
    local nonce_text = tostring(token)
    local cut = math.floor(#nonce_text / 2)
    local nonce_piece_1 = nonce_text:sub(1, cut)
    local nonce_piece_2 = nonce_text:sub(cut + 1)
    local expected_piece_2 = digest % 1000003
    local expected_piece_1 = digest - expected_piece_2

    return ([=[
do
    local _at_score = 0
    local _at_reasons = {}
    local _at_rawget = rawget
    local _at_type = type
    local _at_pcall = pcall
    local _at_tostring = tostring
    local _at_global = _G
    local _at_debug = _at_rawget(_at_global, "debug")

    local function _at_flag(weight, reason)
        _at_score = _at_score + weight
        _at_reasons[#_at_reasons + 1] = reason
    end

    local function _at_hash(value)
        local _at_state = 2166136261 %% 2147483647
        for _at_index = 1, #value do
            _at_state = (_at_state + value:byte(_at_index) * 16777619) %% 2147483647
            _at_state = (_at_state * 48271) %% 2147483647
        end
        return _at_state
    end

    -- Never embed the tripwire constants as single literals: the nonce is two
    -- concatenated string pieces and the expected digest is the sum of two
    -- separately-embedded addends. Rewriting one visible constant breaks
    -- reality; repairing the guard means recomputing the digest and reproducing
    -- the exact split.
    local _at_nonce = %q .. %q
    local _at_expected = ((%d) + (%d))

    if _at_hash(_at_nonce) ~= _at_expected then
        _at_flag(3, "internal-integrity")
    end

    if not (%s) and _at_type(_at_debug) == "table" then
        local _at_ok, _at_hook = _at_pcall(_at_debug.gethook)
        if _at_ok and _at_hook ~= nil then
            _at_flag(2, "debug-hook")
        end
    end

    if %s then
        local _at_signatures = {
            "getgenv", "getrenv", "getgc", "getreg", "getconnections",
            "hookfunction", "hookmetamethod", "newcclosure", "iscclosure",
            "islclosure", "isexecutorclosure", "identifyexecutor",
            "queue_on_teleport", "request", "http_request", "syn",
            "cloneref", "gethui", "firetouchinterest", "setthreadidentity",
            "getthreadidentity", "checkcaller", "getcallingscript",
            "getscriptbytecode", "dumpstring", "getsenv", "setclipboard",
            "getnilinstances", "getproto", "getprotos", "getupvalues",
            "setupvalue", "getconstants", "setconstant", "getstack",
            "getcallstack", "decompile", "saveinstance", "getscripthash",
            "getscriptclosure", "getrawmetatable", "setrawmetatable",
            "setreadonly", "isreadonly", "getcustomasset", "readfile",
            "writefile", "listfiles", "makefolder", "appendfile", "isfile",
            "isfolder", "delfile", "getloadedmodules", "getrunningscripts",
            "getinstances", "getcallbackvalue", "getthreadidentity",
            "setfpscap", "getfpscap", "lz4compress", "lz4decompress",
            "getrenderproperty", "setrenderproperty", "isrenderobj",
            "cleardrawcache", "fireproximityprompt", "fireclickdetector",
            "firesignal", "getscriptfunction", "loadstring_env", "crypt"
        }
        local _at_found = 0
        for _, _at_name in ipairs(_at_signatures) do
            if _at_rawget(_at_global, _at_name) ~= nil then
                _at_found = _at_found + 1
            end
        end
        if _at_found >= 2 then
            _at_flag(3, "executor-signature")
        end
        -- Unambiguous executor / injector markers: any single one is decisive.
        local _at_markers = {
            "KRNL_LOADED", "SYNAPSE_LOADED", "PROTOSMASHER_LOADED", "IS_CVXE",
            "secure_load", "is_synapse_function", "syn_context_get",
            "is_sirhurt_closure", "getexecutorname", "Drawing", "WebSocket",
            "fluxus", "Fluxus", "getgc"
        }
        for _, _at_name in ipairs(_at_markers) do
            if _at_rawget(_at_global, _at_name) ~= nil then
                _at_flag(4, "executor-marker")
                break
            end
        end
    end

    if %s then
        local _at_expected = {
            "assert", "error", "ipairs", "next", "pairs", "pcall",
            "select", "tonumber", "tostring", "type", "xpcall"
        }
        -- Snapshot the core functions from the lexically-bound locals captured at
        -- chunk load (not re-read from _G), so a pre-installed replacement of these
        -- globals is still detected instead of being compared against itself.
        local _at_baseline = {
            pcall = _at_pcall, type = _at_type, tostring = _at_tostring,
            rawget = _at_rawget
        }
        -- Compare each core global against the reference bound at guard-load time.
        -- A host that swapped _G[name] before this chunk ran will have a different
        -- identity than the bindings we captured here, so the mismatch is real.
        local _at_changed = 0
        if _at_baseline.pcall and _at_baseline.type and _at_baseline.tostring and _at_baseline.rawget then
            for _, _at_name in ipairs(_at_expected) do
                local _at_bound = _at_baseline[_at_name]
                if _at_bound ~= nil then
                    if _at_rawget(_at_global, _at_name) ~= _at_bound then
                        _at_changed = _at_changed + 1
                    end
                end
            end
            if _at_changed >= 2 then
                _at_flag(2, "protected-global-replacement")
            elseif _at_changed == 1 then
                _at_flag(1, "global-replacement")
            end
        end

        if _at_type(_at_debug) == "table" and _at_type(_at_debug.getinfo) == "function" then
            local _at_non_native = 0
            for _, _at_name in ipairs(_at_expected) do
                local _at_value = _at_rawget(_at_global, _at_name)
                if _at_type(_at_value) ~= "function" then
                    _at_non_native = _at_non_native + 1
                else
                    local _at_ok, _at_info = _at_pcall(_at_debug.getinfo, _at_value, "S")
                    if _at_ok and _at_info and _at_info.what ~= "C" then
                        _at_non_native = _at_non_native + 1
                    end
                end
            end
            if _at_non_native >= 2 then
                _at_flag(2, "non-native-core-functions")
            end
        end
    end

    local _at_env = _at_rawget(_at_global, "_ENV")
    if _at_env ~= nil and _at_env ~= _at_global then
        _at_flag(2, "environment-divergence")
    end

    if %s and _at_type(_at_debug) == "table" and _at_type(_at_debug.getinfo) == "function" then
        local _at_names = {
            "gethook", "getinfo", "getlocal", "getregistry", "getupvalue",
            "sethook", "setlocal", "setupvalue", "traceback"
        }
        local _at_changed = 0
        for _, _at_name in ipairs(_at_names) do
            local _at_value = _at_rawget(_at_debug, _at_name)
            if _at_type(_at_value) ~= "function" then
                _at_changed = _at_changed + 1
            else
                local _at_ok, _at_info = _at_pcall(_at_debug.getinfo, _at_value, "S")
                if _at_ok and _at_info and _at_info.what ~= "C" then
                    _at_changed = _at_changed + 1
                end
            end
        end
        if _at_changed >= 2 then
            _at_flag(2, "debug-api-replacement")
        end
    end

    if %s and _at_type(_at_debug) == "table" and _at_type(_at_debug.getinfo) == "function" then
        local _at_names = { "load", "loadstring", "dofile", "require" }
        local _at_changed = 0
        for _, _at_name in ipairs(_at_names) do
            local _at_value = _at_rawget(_at_global, _at_name)
            if _at_type(_at_value) == "function" then
                local _at_ok, _at_info = _at_pcall(_at_debug.getinfo, _at_value, "S")
                if _at_ok and _at_info and _at_info.what ~= "C" then
                    _at_changed = _at_changed + 1
                end
            end
        end
        if _at_changed >= 2 then
            _at_flag(2, "loader-replacement")
        end
    end

    if %s then
        local _at_ok, _at_meta = _at_pcall(getmetatable, _at_global)
        if _at_ok and _at_type(_at_meta) == "table" and
            (_at_meta.__index ~= nil or _at_meta.__newindex ~= nil) then
            _at_flag(1, "global-metatable-interception")
        end
    end

    if %s then
        local _at_os = _at_rawget(_at_global, "os")
        local _at_clock = _at_type(_at_os) == "table" and _at_os.clock or nil
        if _at_type(_at_clock) == "function" then
            local _at_start = _at_clock()
            local _at_sum = 0
            for _at_i = 1, 200000 do _at_sum = _at_sum + _at_i end
            if _at_sum > 0 and (_at_clock() - _at_start) > 0.5 then
                _at_flag(2, "timing-anomaly")
            end
        end
    end

    if _at_score >= %d then
        local _at_message = "ᴄᴏʟɪѕѕᴇᴜᴍ ︱ Oh Noes!, An error ocurred: 0x7A31"
        if %s then
            local _at_handler = _at_rawget(_at_global, "__COLISSEUM_TAMPER__")
            if _at_type(_at_handler) == "function" then
                _at_pcall(_at_handler, _at_reasons, _at_score)
            end
        elseif %s then
            return
        else
            error(_at_message, 0)
        end
    end
end
    ]=]):format(
        nonce_piece_1,
        nonce_piece_2,
        expected_piece_1,
        expected_piece_2,
        tostring(allow_hooks),
        tostring(detect_executor),
        tostring(detect_globals),
        tostring(detect_debug),
        tostring(detect_loaders),
        tostring(detect_metatable),
        tostring(detect_timing),
        threshold,
        tostring(mode == "callback"),
        tostring(mode == "return")
    ):gsub("_at_", "_" .. tag .. "_")
end

function Step.apply(source, options)
    if type(source) ~= "string" then
        error("anti-tamper: source must be a string")
    end
    options = options or {}
    if type(options) ~= "table" then
        error("anti-tamper: options must be a table")
    end

    local shebang = source:match("^(#![^\n]*\n)")
    if shebang then
        source = source:sub(#shebang + 1)
    else
        shebang = ""
    end
    build_counter = build_counter + 1
    -- Salt for per-build variable-name randomisation. Derived from the source and
    -- caller entropy but never embedded verbatim, so the guard leaks no source.
    -- When an explicit seed is supplied the salt is seed+source only: builds stay
    -- reproducible on demand while every distinct build still gets unique names.
    local salt
    if options.seed ~= nil then
        salt = Crypto.digest(source .. tostring(options.seed))
    else
        salt = Crypto.digest(source .. tostring(options.seed or "") .. tostring(os.time()) .. tostring(os.clock()) .. tostring(build_counter))
    end
    -- Short build nonce for the internal-integrity tripwire. It contains no source,
    -- so the emitted guard no longer embeds (and leaks) a second copy of the whole
    -- program the way earlier versions did. The global build_counter is only folded
    -- in when no explicit seed is given, so a seeded build reproduces exactly.
    local nonce
    if options.seed ~= nil then
        nonce = tostring(salt)
    else
        nonce = tostring(salt) .. "." .. tostring(build_counter) .. "." .. tostring(os.clock())
    end
    local nonce_digest = Crypto.digest(nonce)
    return shebang .. make_guard(options, salt, nonce, nonce_digest) .. "\n" .. source
end

setmetatable(Step, {
    __call = function(self, source, options)
        return self.apply(source, options)
    end
})

return Step
