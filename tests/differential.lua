-- Deterministic differential harness. Only the fixed fixtures below are run.
-- In particular, this file never searches for or executes fuzz-generated source.
local source_path = debug.getinfo(1, "S").source:sub(2)
local root = source_path:match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local Obfuscator = require("src.obfuscator")

local fixtures = {
    "arithmetic.lua",
    "tables.lua",
    "control-flow.lua"
}
-- Easy is the built-in preset whose generated Lua is also accepted by the
-- restricted CLBC interpreter. Native-runtime coverage remains in tests/run.lua.
local presets = { "easy" }
local passed, failed = 0, 0

local function read_file(path)
    local file = assert(io.open(path, "rb"))
    local value = file:read("*a")
    file:close()
    return value
end

local function shell_quote(value)
    if package.config:sub(1, 1) == "\\" then
        value = value:gsub("/", "\\")
        if not value:find("%s") then return value end
        return '"' .. value:gsub('"', '""') .. '"'
    end
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function local_temp(suffix)
    local name = os.tmpname():match("[^/\\]+$") or ("colisseum_" .. tostring(os.time()))
    return name .. suffix
end

local function value_string(value)
    local kind = type(value)
    if value == nil then return "nil" end
    if kind == "string" then return "string:" .. value end
    if kind == "number" then return "number:" .. string.format("%.17g", value) end
    if kind == "boolean" then return "boolean:" .. tostring(value) end
    return kind .. ":" .. tostring(value)
end

local function result_string(values, count)
    local result = { "count=" .. count }
    for index = 1, count do
        result[#result + 1] = index .. "=" .. value_string(values[index])
    end
    return table.concat(result, "|")
end

local function restricted_result(source)
    local values, stats = Obfuscator.execute(source, {
        steps = 10000,
        depth = 64,
        loop_iterations = 1000
    })
    local count = #values
    return result_string(values, count), stats
end

local function find_luau()
    local configured = os.getenv("COLISSEUM_LUAU")
    local candidates = {}
    if configured and configured ~= "" then candidates[#candidates + 1] = configured end
    candidates[#candidates + 1] = root .. "/build/luau/luau"
    candidates[#candidates + 1] = root .. "/build/luau/Release/luau.exe"
    candidates[#candidates + 1] = root .. "/build/luau/Debug/luau.exe"
    for _, candidate in ipairs(candidates) do
        local file = io.open(candidate, "rb")
        if file then file:close(); return candidate end
    end

    local command = package.config:sub(1, 1) == "\\" and "where luau 2>NUL" or "command -v luau 2>/dev/null"
    local pipe = io.popen(command, "r")
    if pipe then
        local candidate = pipe:read("*l")
        pipe:close()
        if candidate and candidate ~= "" then return candidate end
    end
end

local function luau_runner(source)
    return [[
 local function chunk()
]] .. source .. [[
 end
 local packed = { pcall(chunk) }
if not packed[1] then error(packed[2]) end
local count = #packed - 1
local values = {}
for index = 1, count do values[index] = packed[index + 1] end
local function value_string(value)
    if value == nil then return "nil" end
    local kind = type(value)
    if kind == "string" then return "string:" .. value end
    if kind == "number" then return "number:" .. string.format("%.17g", value) end
    if kind == "boolean" then return "boolean:" .. tostring(value) end
    return kind .. ":" .. tostring(value)
end
local result = { "count=" .. count }
for index = 1, count do result[#result + 1] = index .. "=" .. value_string(values[index]) end
print(table.concat(result, "|"))
]]
end

local function run_luau(executable, source, tag)
    local suffix = tostring(os.time()) .. "_" .. tag:gsub("[^%w]", "_")
    local input_path = local_temp("_input_" .. suffix .. ".lua")
    local runner_path = local_temp("_runner_" .. suffix .. ".lua")
    local input = assert(io.open(input_path, "wb"))
    input:write(source); input:close()
    local runner = assert(io.open(runner_path, "wb"))
    runner:write(luau_runner(source)); runner:close()
    local output_path = local_temp("_output_" .. suffix .. ".txt")
    local command = shell_quote(executable) .. " " .. shell_quote(runner_path) .. " " .. shell_quote(input_path) ..
        " > " .. shell_quote(output_path) .. " 2>&1"
    local status = os.execute(command)
    local output = read_file(output_path):gsub("[\r\n]+$", "")
    os.remove(input_path); os.remove(runner_path); os.remove(output_path)
    if status ~= true and status ~= 0 then
        error("Luau failed for " .. tag .. ": " .. output)
    end
    return output
end

local luau = find_luau()
if luau then
    io.stdout:write("Luau: " .. luau .. "\n")
else
    io.stdout:write("Luau: SKIP (official executable not found; set COLISSEUM_LUAU to enable)\n")
end

for _, fixture in ipairs(fixtures) do
    local path = root .. "/tests/fixtures/" .. fixture
    local original = read_file(path)
    local expected, original_stats = restricted_result(original)
    io.stdout:write("FIXTURE " .. fixture .. " original=" .. expected .. " steps=" .. original_stats.steps .. "\n")
    for _, preset in ipairs(presets) do
        local output = Obfuscator.obfuscate(original, { preset = preset, target = "lua" })
        local actual, obfuscated_stats = restricted_result(output)
        local label = fixture .. " [" .. preset .. "]"
        if actual ~= expected then
            failed = failed + 1
            io.stdout:write("FAIL " .. label .. " restricted=" .. actual .. " expected=" .. expected .. "\n")
        else
            passed = passed + 1
            io.stdout:write("PASS " .. label .. " restricted=" .. actual .. " steps=" .. obfuscated_stats.steps .. "\n")
        end
        if luau then
            local original_luau = run_luau(luau, original, fixture .. "_original")
            local output_luau = run_luau(luau, output, fixture .. "_" .. preset)
            if original_luau ~= output_luau then
                failed = failed + 1
                io.stdout:write("FAIL " .. label .. " luau=" .. output_luau .. " expected=" .. original_luau .. "\n")
            else
                passed = passed + 1
                io.stdout:write("PASS " .. label .. " luau=" .. output_luau .. "\n")
            end
        end
    end
end

io.stdout:write("Results: " .. passed .. " passed, " .. failed .. " failed\n")
if failed > 0 then os.exit(1) end
