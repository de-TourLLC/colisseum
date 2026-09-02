local Step = {}
local build_counter = 0
local Crypto = require("src.steps.security.crypto")

Step.name = "anti-tamper"
Step.version = 5

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
    -- Detect post-load hooks of core stdlib functions (string/table/math) by
    -- identity divergence from the pristine baseline captured at chunk load.
    local detect_stdlib = boolean_option(options, "detectStdlib", true)
    -- Deferred re-scan: exploits usually inject AFTER the game loads, so a single
    -- startup scan misses them. recheckDelay = seconds to wait after load before
    -- the second scan (0/false disables the deferred pass). recheckAfterLoad waits
    -- for the game to finish loading first. Both are no-ops with no scheduler.
    local recheck_delay
    if options.recheckDelay == false or options.recheckDelay == 0 then
        recheck_delay = 0
    else
        recheck_delay = number_option(options, "recheckDelay", 3)
    end
    local recheck_after_load = boolean_option(options, "recheckAfterLoad", true)
    -- Prometheus-style anti-beautify: detect that the shipped output was run
    -- through a code beautifier / pretty-printer (a common first step before
    -- manual analysis). You cannot make valid Lua break on whitespace, so instead
    -- the guard emits TWO `error()` probes on a SINGLE physical line and compares
    -- the line numbers Lua reports for them (parsed from the error text -- no
    -- `debug` needed, so it works inside the sandbox). Minified output keeps both
    -- on one line (equal); a beautifier that puts each statement on its own line
    -- makes them diverge. Per-build markers keep it from being a fixed signature.
    local detect_beautify = boolean_option(options, "detectBeautify", true)
    local mark_a = "b" .. tostring(tag) .. "za"
    local mark_b = "b" .. tostring(tag) .. "zb"
    -- One physical line. `_at_pcall`/`_at_tostring`/`_at_flag` are in scope inside
    -- _at_scan where this is spliced. The `%d` here is NOT a format specifier --
    -- it lives inside a format ARGUMENT, so it is copied through verbatim.
    local beautify_line = ""
    if detect_beautify then
        beautify_line =
            "local _at_l1,_at_l2 do " ..
            "local _,_at_e1=_at_pcall(function() error(\"" .. mark_a .. "\",1) end) " ..
            "local _,_at_e2=_at_pcall(function() error(\"" .. mark_b .. "\",1) end) " ..
            "_at_l1=tonumber((_at_tostring(_at_e1)):match(\":(%d+): " .. mark_a .. "\")) " ..
            "_at_l2=tonumber((_at_tostring(_at_e2)):match(\":(%d+): " .. mark_b .. "\")) end " ..
            "if _at_l1 and _at_l2 and _at_l1 ~= _at_l2 then _at_flag(4, \"source-reformatted\") end"
    end

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
    local _at_rawget = rawget
    local _at_type = type
    local _at_pcall = pcall
    local _at_tostring = tostring
    local _at_ipairs = ipairs
    local _at_pairs = pairs
    local _at_global = _G
    local _at_debug = _at_rawget(_at_global, "debug")

    -- Per-build configuration, baked once and referenced by both the immediate and
    -- the deferred scan so the two stay in lockstep.
    local _at_threshold = (%d)
    local _at_mode_cb = %s
    local _at_mode_ret = %s
    local _at_allow_hooks = %s
    local _at_do_executor = %s
    local _at_do_globals = %s
    local _at_do_debug = %s
    local _at_do_loaders = %s
    local _at_do_metatable = %s
    local _at_do_timing = %s
    local _at_do_stdlib = %s
    local _at_recheck_delay = (%s)
    local _at_recheck_after_load = %s
    local _at_message = "ᴄᴏʟɪѕѕᴇᴜᴍ ︱ Oh Noes!, An error ocurred: 0x7A31"

    -- Pristine baselines captured at chunk load, BEFORE any post-load tampering.
    -- The deferred scan compares the live environment against these, so a hook
    -- installed after the game loads is caught as an identity divergence -- not
    -- compared against a value the exploit already replaced.
    local _at_core_names = {
        "assert", "error", "ipairs", "next", "pairs", "pcall",
        "select", "tonumber", "tostring", "type", "xpcall"
    }
    local _at_base_core = {}
    for _, _at_n in _at_ipairs(_at_core_names) do
        _at_base_core[_at_n] = _at_rawget(_at_global, _at_n)
    end
    -- Snapshot stdlib table functions (string/table/math). hookfunction swaps the
    -- table slot for a fresh closure, so identity divergence is a reliable tell.
    local _at_lib_names = { "string", "table", "math" }
    local _at_base_lib = {}
    for _, _at_ln in _at_ipairs(_at_lib_names) do
        local _at_lib = _at_rawget(_at_global, _at_ln)
        if _at_type(_at_lib) == "table" then
            local _at_snap = {}
            for _at_k, _at_v in _at_pairs(_at_lib) do
                if _at_type(_at_v) == "function" then _at_snap[_at_k] = _at_v end
            end
            _at_base_lib[_at_ln] = _at_snap
        end
    end
    -- Original metatables of the core string library table, so a later
    -- setrawmetatable / __index swap on it (a common global-hook vector) shows up.
    local _at_base_meta = {}
    do
        local _at_ok, _at_mt = _at_pcall(getmetatable, "")
        if _at_ok then _at_base_meta.str = _at_mt end
    end

    -- Never embed the tripwire constants as single literals: the nonce is two
    -- concatenated string pieces and the expected digest is the sum of two
    -- separately-embedded addends. Rewriting one visible constant breaks
    -- reality; repairing the guard means recomputing the digest and reproducing
    -- the exact split.
    local _at_nonce = %q .. %q
    local _at_expected = ((%d) + (%d))

    local function _at_hash(value)
        local _at_state = 2166136261 %% 2147483647
        for _at_index = 1, #value do
            _at_state = (_at_state + value:byte(_at_index) * 16777619) %% 2147483647
            _at_state = (_at_state * 48271) %% 2147483647
        end
        return _at_state
    end

    -- One complete environment scan. Pure with respect to the captured baselines,
    -- so it is safe to run once at startup and again later against a mutated host.
    local function _at_scan()
        local _at_score = 0
        local _at_reasons = {}
        local function _at_flag(weight, reason)
            _at_score = _at_score + weight
            _at_reasons[#_at_reasons + 1] = reason
        end

        if _at_hash(_at_nonce) ~= _at_expected then
            _at_flag(3, "internal-integrity")
        end

        if not (_at_allow_hooks) and _at_type(_at_debug) == "table" then
            local _at_ok, _at_hook = _at_pcall(_at_debug.gethook)
            if _at_ok and _at_hook ~= nil then
                _at_flag(2, "debug-hook")
            end
        end

        if _at_do_executor then
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
            for _, _at_name in _at_ipairs(_at_signatures) do
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
            for _, _at_name in _at_ipairs(_at_markers) do
                if _at_rawget(_at_global, _at_name) ~= nil then
                    _at_flag(4, "executor-marker")
                    break
                end
            end
        end

        if _at_do_globals then
            -- Compare each live core global against its pristine baseline. A host
            -- that swapped _G[name] -- before OR after load -- diverges from the
            -- identity captured at chunk load.
            local _at_changed = 0
            for _at_name, _at_bound in _at_pairs(_at_base_core) do
                if _at_bound ~= nil and _at_rawget(_at_global, _at_name) ~= _at_bound then
                    _at_changed = _at_changed + 1
                end
            end
            if _at_changed >= 2 then
                _at_flag(2, "protected-global-replacement")
            elseif _at_changed == 1 then
                _at_flag(1, "global-replacement")
            end

            if _at_type(_at_debug) == "table" and _at_type(_at_debug.getinfo) == "function" then
                local _at_non_native = 0
                for _, _at_name in _at_ipairs(_at_core_names) do
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

        if _at_do_stdlib then
            -- Any stdlib function whose live identity no longer matches the one
            -- snapshotted at load has been hooked (hookfunction / replaced slot).
            local _at_hooked = 0
            for _at_ln, _at_snap in _at_pairs(_at_base_lib) do
                local _at_lib = _at_rawget(_at_global, _at_ln)
                if _at_type(_at_lib) == "table" then
                    for _at_k, _at_orig in _at_pairs(_at_snap) do
                        if _at_lib[_at_k] ~= _at_orig then
                            _at_hooked = _at_hooked + 1
                        end
                    end
                end
            end
            if _at_hooked >= 1 then
                _at_flag(2, "stdlib-function-hook")
            end
            -- A native stdlib function that has become a Lua closure was wrapped.
            if _at_type(_at_debug) == "table" and _at_type(_at_debug.getinfo) == "function" then
                local _at_probe = {
                    { "string", "char" }, { "string", "byte" }, { "string", "sub" },
                    { "table", "concat" }, { "table", "insert" }, { "math", "floor" }
                }
                local _at_nonc = 0
                for _, _at_p in _at_ipairs(_at_probe) do
                    local _at_lib = _at_rawget(_at_global, _at_p[1])
                    local _at_fn = _at_type(_at_lib) == "table" and _at_lib[_at_p[2]] or nil
                    if _at_type(_at_fn) == "function" then
                        local _at_ok, _at_info = _at_pcall(_at_debug.getinfo, _at_fn, "S")
                        if _at_ok and _at_info and _at_info.what ~= "C" then
                            _at_nonc = _at_nonc + 1
                        end
                    end
                end
                if _at_nonc >= 1 then
                    _at_flag(2, "stdlib-non-native")
                end
            end
            -- The string library's metatable was swapped after load (setrawmetatable
            -- on the string type is a classic global-hook / sandbox-escape vector).
            local _at_ok, _at_mt = _at_pcall(getmetatable, "")
            if _at_ok and _at_base_meta.str ~= nil and _at_mt ~= _at_base_meta.str then
                _at_flag(2, "string-metatable-swap")
            end
        end

        local _at_env = _at_rawget(_at_global, "_ENV")
        if _at_env ~= nil and _at_env ~= _at_global then
            _at_flag(2, "environment-divergence")
        end

        if _at_do_debug and _at_type(_at_debug) == "table" and _at_type(_at_debug.getinfo) == "function" then
            local _at_names = {
                "gethook", "getinfo", "getlocal", "getregistry", "getupvalue",
                "sethook", "setlocal", "setupvalue", "traceback"
            }
            local _at_changed = 0
            for _, _at_name in _at_ipairs(_at_names) do
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

        if _at_do_loaders and _at_type(_at_debug) == "table" and _at_type(_at_debug.getinfo) == "function" then
            local _at_names = { "load", "loadstring", "dofile", "require" }
            local _at_changed = 0
            for _, _at_name in _at_ipairs(_at_names) do
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

        if _at_do_metatable then
            local _at_ok, _at_meta = _at_pcall(getmetatable, _at_global)
            if _at_ok and _at_type(_at_meta) == "table" and
                (_at_meta.__index ~= nil or _at_meta.__newindex ~= nil) then
                _at_flag(1, "global-metatable-interception")
            end
        end

        if _at_do_timing then
            local _at_os = _at_rawget(_at_global, "os")
            local _at_clock = _at_type(_at_os) == "table" and _at_os.clock or nil
            if _at_type(_at_clock) == "function" then
                -- Calibrate to THIS host's speed instead of an absolute wall-clock
                -- bound. A fixed "> 0.5s" threshold false-positives on any
                -- legitimately slow host (a throttled CPU, a mobile device, or an
                -- interpreted/embedded Lua host). Time a small warmup loop, then a
                -- loop ten times larger, and flag only a GROSS disproportion a
                -- uniform slowdown cannot explain -- the ratio stays ~10x on an
                -- honestly-slow host. Installed hooks (the primary threat this
                -- approximates) are already caught by the debug-hook detector.
                local _at_c0 = _at_clock()
                local _at_warm = 0
                for _at_i = 1, 20000 do _at_warm = _at_warm + _at_i end
                local _at_unit = _at_clock() - _at_c0
                local _at_c1 = _at_clock()
                local _at_sum = 0
                for _at_i = 1, 200000 do _at_sum = _at_sum + _at_i end
                local _at_main = _at_clock() - _at_c1
                -- The big loop is 10x the warmup, so ~10x its time is normal. A
                -- genuine per-op instrumentation hook inflates it by 100-1000x, so
                -- require a >=150x blowout: far above any GC/scheduler jitter or
                -- coarse-`os.clock` single-tick rounding, yet still tripped by real
                -- tracing. Timing is only a backstop -- installed hooks are caught
                -- deterministically by the debug-hook detector above.
                if _at_warm > 0 and _at_sum > 0 and _at_unit > 0 and _at_main > (_at_unit * 150) then
                    _at_flag(2, "timing-anomaly")
                end
            end
        end

        %s

        return _at_score, _at_reasons
    end

    -- Deferred reaction: callback or hard error. It cannot silently `return` the
    -- already-running chunk, so `return` mode simply omits the deferred trip.
    local function _at_react(_at_s, _at_r)
        if _at_s >= _at_threshold then
            if _at_mode_cb then
                local _at_handler = _at_rawget(_at_global, "__COLISSEUM_TAMPER__")
                if _at_type(_at_handler) == "function" then
                    _at_pcall(_at_handler, _at_r, _at_s)
                end
            elseif _at_mode_ret then
                -- deferred: nothing to abort
            else
                error(_at_message, 0)
            end
        end
    end

    -- Immediate scan. `return` here still aborts the chunk, preserving that mode.
    local _at_s0, _at_r0 = _at_scan()
    if _at_s0 >= _at_threshold then
        if _at_mode_cb then
            local _at_handler = _at_rawget(_at_global, "__COLISSEUM_TAMPER__")
            if _at_type(_at_handler) == "function" then
                _at_pcall(_at_handler, _at_r0, _at_s0)
            end
        elseif _at_mode_ret then
            return
        else
            error(_at_message, 0)
        end
    end

    -- Deferred re-check. Exploits overwhelmingly inject AFTER the game has loaded,
    -- so a single startup scan is blind to them. When a Roblox-style scheduler is
    -- present, run a background thread that (optionally) waits for the game to load,
    -- waits the configured delay, then scans again against the pristine baseline.
    -- With no scheduler (plain Lua, the tree-walker, embedded hosts) there is
    -- nothing to defer onto, so this whole block is skipped without side effects.
    if _at_recheck_delay and _at_recheck_delay > 0 then
        local _at_task = _at_rawget(_at_global, "task")
        local _at_spawn = _at_type(_at_task) == "table" and _at_task.spawn or nil
        local _at_wait = _at_type(_at_task) == "table" and _at_task.wait or nil
        if _at_type(_at_spawn) == "function" and _at_type(_at_wait) == "function" then
            _at_spawn(function()
                if _at_recheck_after_load then
                    local _at_game = _at_rawget(_at_global, "game")
                    if _at_game ~= nil then
                        -- Poll IsLoaded without method syntax; cap the wait so a
                        -- missing/renamed API can never hang the thread.
                        local _at_guard = 0
                        while _at_guard < 900 do
                            local _at_ok, _at_loaded = _at_pcall(function()
                                local _at_fn = _at_game.IsLoaded
                                if _at_type(_at_fn) == "function" then return _at_fn(_at_game) end
                                return true
                            end)
                            if (not _at_ok) or _at_loaded then break end
                            _at_pcall(_at_wait)
                            _at_guard = _at_guard + 1
                        end
                    end
                end
                _at_pcall(_at_wait, _at_recheck_delay)
                local _at_s1, _at_r1 = _at_scan()
                _at_react(_at_s1, _at_r1)
            end)
        end
    end
end
    ]=]):format(
        threshold,
        tostring(mode == "callback"),
        tostring(mode == "return"),
        tostring(allow_hooks),
        tostring(detect_executor),
        tostring(detect_globals),
        tostring(detect_debug),
        tostring(detect_loaders),
        tostring(detect_metatable),
        tostring(detect_timing),
        tostring(detect_stdlib),
        tostring(recheck_delay),
        tostring(recheck_after_load),
        nonce_piece_1,
        nonce_piece_2,
        expected_piece_1,
        expected_piece_2,
        beautify_line
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
