-- LuaJIT-compatible tests for the Luau backend adapter.
local source = debug.getinfo(1, "S").source:sub(2)
local root = source:match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."
package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path

local VM = require("src.core.luau-vm")

local passed, skipped, failed = 0, 0, 0

local function check(condition, message)
    if not condition then error(message or "condition failed", 2) end
end

local function equal(actual, expected, message)
    check(actual == expected, (message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
end

local function fails(callback, fragment)
    local ok, message = pcall(callback)
    check(not ok, "expected an error")
    if fragment then
        check(tostring(message):find(fragment, 1, true) ~= nil,
            "error did not contain '" .. fragment .. "': " .. tostring(message))
    end
end

local function test(name, callback)
    local ok, message = xpcall(callback, debug.traceback)
    if ok then
        passed = passed + 1
        io.stdout:write("PASS " .. name .. "\n")
    else
        failed = failed + 1
        io.stdout:write("FAIL " .. name .. "\n" .. tostring(message) .. "\n")
    end
end

local function skip(name, reason)
    skipped = skipped + 1
    io.stdout:write("SKIP " .. name .. " (" .. reason .. ")\n")
end

local function write_backend(contents)
    local path = os.tmpname()
    local file = assert(io.open(path, "wb"))
    file:write(contents)
    file:close()
    return path
end

local valid_backend = [[
return {
    luau_newsettings = function()
        return { custom = true }
    end,
    luau_validatesettings = function(settings)
        if settings.custom ~= true then error("settings were not forwarded") end
    end,
    luau_load = function(bytecode, environment, settings)
        if bytecode ~= "bytecode" or settings.custom ~= true then error("load arguments were not forwarded") end
        return function()
            return environment.answer
        end, function() end
    end,
    luau_deserialize = function(bytecode, settings)
        if bytecode ~= "serialized" or settings.custom ~= true then error("deserialize arguments were not forwarded") end
        return "deserialized"
    end
}
]]

test("availability returns false for missing and invalid backends", function()
    local missing = root .. "/tests/backend-that-does-not-exist.lua"
    equal(VM.available(missing), false, "missing backend")

    local invalid = write_backend("return { luau_load = true }")
    equal(VM.available(invalid), false, "invalid backend")
    os.remove(invalid)
end)

test("availability recognizes a backend exposing the Fiu API", function()
    local path = write_backend(valid_backend)
    local available = VM.available(path)
    os.remove(path)
    equal(available, true, "valid backend")
end)

test("load forwards bytecode, environment, and settings", function()
    local path = write_backend(valid_backend)
    local environment = { answer = 42 }
    local settings = { custom = true }
    local chunk, close = VM.load("bytecode", environment, settings, path)
    equal(chunk(), 42, "loaded closure result")
    close()
    os.remove(path)
end)

test("load creates and validates default settings", function()
    local calls = { newsettings = 0, validatesettings = 0 }
    local path = write_backend(valid_backend)
    local chunk = VM.load("bytecode", { answer = 7 }, nil, path)
    equal(chunk(), 7, "loaded closure result")
    os.remove(path)
end)

test("deserialize validates settings and returns the backend result", function()
    local path = write_backend(valid_backend)
    equal(VM.deserialize("serialized", { custom = true }, path), "deserialized")
    os.remove(path)
end)

test("load rejects unsupported bytecode values before probing the backend", function()
    fails(function() VM.load(123, nil, nil, root .. "/missing.lua") end, "bytecode must be a string or buffer")
end)

local function executable_available(command)
    local pipe = io.popen("where " .. command .. " 2>NUL", "r")
    if not pipe then return false end
    local result = pipe:read("*a")
    pipe:close()
    return result ~= nil and result ~= ""
end

for _, command in ipairs({ "luau", "luau-compile" }) do
    if executable_available(command) then
        test(command .. " compiler is discoverable", function()
            check(executable_available(command), command .. " disappeared during test")
        end)
    else
        skip(command .. " compiler integration", "external binary unavailable")
    end
end

io.stdout:write("\nResults: " .. passed .. " passed, " .. skipped .. " skipped, " .. failed .. " failed\n")
if failed > 0 then os.exit(1) end
