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

-- Progress bar + rotating funny tips shown on stderr while the pipeline runs.
math.randomseed(os.time() + math.floor(((os.clock() or 0) * 1e6) % 1e6))
local USE_COLOR = not os.getenv("NO_COLOR")
local TIPS = {
    "Permutando opcodes pa' que el skid llore",
    "Cifrando con ChaCha (no la de tu barrio)",
    "Metiendo capas como lasagna",
    "El deobfuscador ya esta sudando frio",
    "Renombrando todo a itzCool_jLjLjL",
    "Si lo crackean, avisame como lo hiciste",
    "task.wait() pa' que Roblox no se queje",
    "Inyectando codigo basura gourmet",
    "Bytecode mas encriptado que tu ex bloqueado",
    "Cada build es unico, como vos rey",
    "Confundiendo al de IDA Pro",
    "Aplanando el control flow hasta marear",
    "Predicados opacos: matematica para llorar",
    "Roblox no sabe lo que le espera",
    "Escondiendo strings como secretos",
    "Anti-tamper activado, no toques nada",
    "Esto no lo abre ni con paciencia",
    "Generando ruido pa' despistar",
    "Detectando executors chismosos",
    "El VM quedo mas ofuscado que mi vida",
    "Comprimiendo maldad en una sola linea",
    "99 problemas pero un deobf no es uno",
    "Lento de crackear a proposito, de nada",
    "Casi listo, aguanta el ansia",
    "Mezclando el bytecode como DJ",
    "Poniendo trampas para curiosos",
}
local last_tip
local function pick_tip()
    if #TIPS <= 1 then return TIPS[1] or "" end
    local t
    repeat t = TIPS[math.random(#TIPS)] until t ~= last_tip
    last_tip = t
    return t
end
local function progress(done, total, step)
    local width = 22
    local ratio = total > 0 and (done / total) or 1
    if ratio > 1 then ratio = 1 end
    local filled = math.floor(width * ratio + 0.5)
    local bar = string.rep("#", filled) .. string.rep("-", width - filled)
    local pct = math.floor(ratio * 100 + 0.5)
    local label = step
    if step == "vm" then label = "empaquetando VM (tarda)" end
    if step == "done" then label = "listo!" end
    local tip = pick_tip()
    if USE_COLOR then
        io.stderr:write(string.format("\r\027[36m  [%s]\027[0m \027[1m%3d%%\027[0m  \027[90m%-24s\027[0m \027[33m%s\027[0m\027[K",
            bar, pct, label, tip))
    else
        io.stderr:write(string.format("\r  [%s] %3d%%  %-24s %s   ", bar, pct, label, tip))
    end
    io.stderr:flush()
    if step == "done" or done >= total then io.stderr:write("\n") end
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
