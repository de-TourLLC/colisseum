local function banner()
    -- Pure ASCII so it renders correctly in every terminal and code page
    -- (the previous Unicode block art showed as mojibake on Windows consoles).
    local art = [[
    ::::::::   ::::::::  :::        ::::::::::: ::::::::   ::::::::  :::::::::: :::    ::: ::::    ::::  
    :+:    :+: :+:    :+: :+:            :+:    :+:    :+: :+:    :+: :+:        :+:    :+: +:+:+: :+:+:+ 
    +:+        +:+    +:+ +:+            +:+    +:+        +:+        +:+        +:+    +:+ +:+ +:+:+ +:+ 
    +#+        +#+    +:+ +#+            +#+    +#++:++#++ +#++:++#++ +#++:++#   +#+    +:+ +#+  +:+  +#+ 
    +#+        +#+    +#+ +#+            +#+           +#+        +#+ +#+        +#+    +#+ +#+       +#+ 
    #+#    #+# #+#    #+# #+#            #+#    #+#    #+# #+#    #+# #+#        #+#    #+# #+#       #+# 
    ########   ########  ########## ########### ########   ########  ##########  ########  ###       ### ]]
    if os.getenv("NO_COLOR") then
        io.stderr:write(art, "\n\n")
    else
        io.stderr:write("\27[35m", art, "\27[0m\n\n")
    end
end

banner()

local Errors = require("src.core.errors")

local function usage()
    io.stderr:write("colisseum: usage:\n")
    io.stderr:write("  lua cli.lua --preset Easy|Medium|Hard|Full|Total|Fortress [--LuaU|--Roblox --secure --backend native|register|fiu --compiler path] --out output.lua input.lua\n")
    io.stderr:write("  Fortress = maximum client hardening on the fast register VM (Lua + Luau/Roblox); every static layer + encrypted, permuted, name-mangled bytecode.\n")
    io.stderr:write("  lua cli.lua --preset <name> --batch --out <output-dir> file1.lua file2.lua ...\n")
    io.stderr:write("  backends: native (default) = tree-walking VM; register = faster register VM (2-6x); both run on\n")
    io.stderr:write("            Lua and Luau/Roblox with no compiler. fiu = real Luau bytecode VM for full Luau syntax (needs --LuaU + compiler).\n")
    os.exit(2)
end

local arguments = { inputs = {} }
local index = 1
local function required_value(option)
    index = index + 1
    if not arg[index] or arg[index]:sub(1, 2) == "--" then
        io.stderr:write("colisseum: missing value for " .. option .. "\n")
        os.exit(2)
    end
    return arg[index]
end
while index <= #arg do
    local value = arg[index]
    if value == "--preset" then
        arguments.preset = required_value(value)
    elseif value == "--out" then
        arguments.output = required_value(value)
    elseif value == "--LuaU" or value == "--Luau" then
        arguments.luau = true
    elseif value == "--Roblox" or value == "--roblox" then
        arguments.luau = true
        arguments.roblox = true
        arguments.secure = true
    elseif value == "--secure" then
        arguments.secure = true
    elseif value == "--compiler" then
        arguments.compiler = required_value(value)
    elseif value == "--fiu" then
        arguments.fiu = required_value(value)
        arguments.backend = "fiu"
    elseif value == "--backend" then
        arguments.backend = required_value(value):lower()
    elseif value == "--batch" then
        arguments.batch = true
    elseif value == "--jobs" then
        arguments.jobs = tonumber(required_value(value))
    elseif value:sub(1, 2) == "--" then
        usage()
    else
        arguments.inputs[#arguments.inputs + 1] = value
    end
    index = index + 1
end

if not arguments.preset or not arguments.output or #arguments.inputs == 0 then usage() end
if not arguments.batch and #arguments.inputs ~= 1 then usage() end

local preset = arguments.preset:lower()
local aliases = { easy = "easy", medium = "medium", hard = "hard", full = "full", total = "total", fortress = "fortress", secure = "secure" }
if not aliases[preset] then
    io.stderr:write("colisseum: unknown preset: " .. arguments.preset .. "\n")
    os.exit(2)
end

local function file_exists(path)
    local file = io.open(path, "rb")
    if file then file:close() return true end
    return false
end

local function script_directory()
    local self = (arg and arg[0]) or "cli.lua"
    return self:match("^(.*)[/\\][^/\\]+$") or "."
end

-- Locate the Luau compiler bundled with the repository (built from vendor/Luau
-- by tools/build-luau.bat). Resolved relative to this script so it works from any
-- working directory; falls back to a repo-root or bin/ binary if present.
local function bundled_luau()
    local root = script_directory()
    local suffix = package.config:sub(1, 1) == "\\" and ".exe" or ""
    local candidates = {
        root .. "/build/luau/Release/luau-compile" .. suffix,
        root .. "/build/luau/luau-compile" .. suffix,
        root .. "/vendor/Luau/build/Release/luau-compile" .. suffix,
        root .. "/vendor/Luau/build/luau-compile" .. suffix,
        root .. "/vendor/luau-compile.bat",
        root .. "/bin/luau-compile" .. suffix,
        root .. "/luau-compile" .. suffix,
    }
    for _, candidate in ipairs(candidates) do
        if file_exists(candidate) then return candidate end
    end
    return nil
end

local obfuscator = require("src.obfuscator")

-- A modern installer-style progress line (braille spinner + smooth bar + ETA +
-- rotating tips), drawn on stderr while the pipeline runs.
math.randomseed(os.time() + math.floor(((os.clock() or 0) * 1e6) % 1e6))
local USE_COLOR = not os.getenv("NO_COLOR")
local SPIN = { "\226\160\139", "\226\160\153", "\226\160\185", "\226\160\184", "\226\160\188",
               "\226\160\180", "\226\160\166", "\226\160\167", "\226\160\135", "\226\160\143" } -- ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏
local BAR_ON, BAR_OFF, CHECK = "\226\148\129", "\226\148\128", "\226\156\148" -- ━ (heavy) ─ (light) ✔
local TIPS = {
    "Permuting opcodes so the skid cries",
    "Encrypting with ChaCha (not the dance)",
    "Stacking layers like a lasagna",
    "The deobfuscator is already sweating",
    "Renaming everything to itzCool_jLjLjL",
    "If you crack this, tell me how you did it",
    "task.wait() so Roblox stops whining",
    "Injecting gourmet junk code",
    "Bytecode more encrypted than your ex's heart",
    "Every build is unique, like you, king",
    "Confusing the guy with IDA Pro open",
    "Flattening control flow until it's dizzy",
    "Opaque predicates: math that makes you weep",
    "Roblox has no idea what's coming",
    "Hiding strings like little secrets",
    "Anti-tamper armed, do not touch anything",
    "Not even patience will open this one",
    "Generating noise to throw them off",
    "Sniffing out nosy executors",
    "The VM is now more obfuscated than my life",
    "Compressing pure evil into a single line",
    "99 problems but a deobf ain't one",
    "Slow to crack on purpose, you're welcome",
    "Almost there, hold your horses",
    "Mixing the bytecode like a DJ",
    "Setting little traps for the curious",
    "Teaching the reverse-engineer some humility",
}
local last_tip
local function pick_tip()
    if #TIPS <= 1 then return TIPS[1] or "" end
    local t
    repeat t = TIPS[math.random(#TIPS)] until t ~= last_tip
    last_tip = t
    return t
end
local function fmt_time(sec)
    if not sec or sec < 0 then sec = 0 end
    if sec >= 60 then return string.format("%dm%02ds", math.floor(sec / 60), math.floor(sec % 60)) end
    return string.format("%.0fs", sec)
end
local prog_start, spin_i, cur_tip, tip_at = nil, 0, nil, 0
-- progress(fraction 0..1, label). Reports a whole-build fraction; the pipeline and
-- the VM backend both feed this so the bar and ETA advance through the slow parts.
local function progress(fraction, label)
    local now = os.clock()
    prog_start = prog_start or now
    if not fraction or fraction < 0 then fraction = 0 elseif fraction > 1 then fraction = 1 end
    local done = label == "done" or fraction >= 1
    if not cur_tip or now - tip_at > 1.1 then cur_tip = pick_tip(); tip_at = now end
    spin_i = (spin_i % #SPIN) + 1
    local width = 26
    local filled = math.floor(width * fraction + 0.5)
    local pct = math.floor(fraction * 100 + 0.5)
    local elapsed = now - prog_start
    local eta = done and elapsed or ((fraction > 0.02) and elapsed * (1 - fraction) / fraction or nil)
    local timetext = (done and "in " or "eta ") .. (eta and fmt_time(eta) or "--")
    local name = (label or ""):gsub("^vm:", "")
    if done then name = "done" end
    if USE_COLOR then
        local mark = done and ("\027[92m" .. CHECK) or ("\027[96m" .. SPIN[spin_i])
        local bar = "\027[96m" .. string.rep(BAR_ON, filled) .. "\027[90m" .. string.rep(BAR_OFF, width - filled)
        io.stderr:write(string.format(
            "\r%s\027[0m \027[1m%-11s\027[0m %s\027[0m \027[1m%3d%%\027[0m \027[90m%-9s\027[0m \027[35m%-22s\027[0m \027[90m%s\027[0m\027[K",
            mark, done and "Done" or "Obfuscating", bar, pct, timetext, name, cur_tip))
    else
        io.stderr:write(string.format("\r%s %-11s [%s%s] %3d%% %-9s %-22s %s   ",
            done and "OK" or ">", done and "Done" or "Obfuscating",
            string.rep("#", filled), string.rep("-", width - filled), pct, timetext, name, cur_tip))
    end
    io.stderr:flush()
    if done then io.stderr:write("\n") end
end

-- Obfuscate one in-memory source string, returning (output, error). Loaded once
-- and reused across every file in a batch, so there is no per-file startup cost.
local function obfuscate_source(source)
    return obfuscator.try(function()
        if arguments.secure or arguments.backend then
            -- Backend selection (VM packaging). native (default) = Colisseum's own
            -- obfuscated tree-walking VM; register = the faster register VM (2-6x);
            -- both need no Luau compiler and run on Lua/LuaJIT and Luau/Roblox. Fiu
            -- (--backend fiu or --fiu <path>) runs real Luau bytecode for full Luau
            -- syntax and requires --LuaU plus the vendored Luau compiler.
            local backend = arguments.backend or "native"
            local compiler
            if backend == "fiu" then
                if not arguments.luau then Errors.raise("--backend fiu requires --LuaU") end
                compiler = arguments.compiler or bundled_luau()
                if not compiler then
                    Errors.raise("the Fiu backend needs the vendored Luau compiler. Run tools\\build-luau.bat once.")
                end
            end
            return obfuscator.package_luau(source, {
                preset = aliases[preset],
                backend = backend,
                target = arguments.luau and "luau" or "lua",
                compiler = compiler,
                fiu = arguments.fiu,
                compiler_options = { roblox = arguments.roblox },
                on_progress = progress
            })
        end
        local transformed = obfuscator.obfuscate(source, {
            preset = aliases[preset],
            target = arguments.luau and "luau" or "lua",
            on_progress = progress
        })
        return transformed
    end)
end

local function read_file(path)
    local handle = io.open(path, "rb")
    if not handle then return nil end
    local value = handle:read("*a")
    handle:close()
    return value
end

local function write_file(path, value)
    local handle, message = io.open(path, "wb")
    if not handle then return nil, message end
    handle:write(value)
    handle:close()
    return true
end

local function basename(path)
    return path:match("[^/\\]+$") or path
end

if not arguments.batch then
    -- Single-file mode.
    local source = read_file(arguments.inputs[1])
    if not source then
        io.stderr:write("colisseum: cannot open input: " .. arguments.inputs[1] .. "\n")
        os.exit(1)
    end
    local output, process_error = obfuscate_source(source)
    if not output then
        io.stderr:write(Errors.message(process_error) .. "\n")
        os.exit(1)
    end
    local ok, message = write_file(arguments.output, output)
    if not ok then
        io.stderr:write("colisseum: cannot write output: " .. tostring(message) .. "\n")
        os.exit(1)
    end
    io.stdout:write("obfuscated " .. arguments.inputs[1] .. " -> " .. arguments.output .. " (" .. preset .. ")\n")
    return
end

-- Batch mode: --out is a directory; obfuscate every input into it, reusing the
-- single loaded obfuscator (one interpreter, no repeated startup cost).
if arguments.jobs and arguments.jobs > 1 then
    io.stderr:write("colisseum: note: --jobs runs in-process (single core). For multi-core, run the\n" ..
        "single-file command in parallel with your shell (PowerShell ForEach-Object -Parallel, or xargs -P).\n")
end
local outdir = arguments.output:gsub("[/\\]+$", "")
local is_windows = package.config:sub(1, 1) == "\\"
os.execute((is_windows and 'if not exist "' .. outdir .. '" mkdir "' .. outdir .. '"'
    or 'mkdir -p "' .. outdir .. '"'))

local succeeded, failed = 0, 0
local started = os.clock()
for _, input_path in ipairs(arguments.inputs) do
    local source = read_file(input_path)
    if not source then
        io.stderr:write("colisseum: cannot open input: " .. input_path .. " (skipped)\n")
        failed = failed + 1
    else
        local output, process_error = obfuscate_source(source)
        if not output then
            io.stderr:write("colisseum: " .. basename(input_path) .. ": " .. Errors.message(process_error) .. "\n")
            failed = failed + 1
        else
            local out_path = outdir .. "/" .. basename(input_path)
            local ok, message = write_file(out_path, output)
            if not ok then
                io.stderr:write("colisseum: cannot write " .. out_path .. ": " .. tostring(message) .. "\n")
                failed = failed + 1
            else
                io.stdout:write("obfuscated " .. input_path .. " -> " .. out_path .. "\n")
                succeeded = succeeded + 1
            end
        end
    end
end
io.stdout:write(string.format("batch: %d succeeded, %d failed (%s preset, %.2fs)\n",
    succeeded, failed, preset, os.clock() - started))
if failed > 0 then os.exit(1) end
