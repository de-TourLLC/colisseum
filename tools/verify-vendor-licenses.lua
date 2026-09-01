-- Offline verification of the vendored submodules and their notices.
-- Run from the repository root: luajit tools/verify-vendor-licenses.lua

local root = arg[1] or "."
local notices_path = root .. "/THIRD_PARTY_NOTICES.md"

local vendors = {
    {
        name = "Fiu",
        path = root .. "/vendor/Fiu",
        revision = "0acebaccc8aa072113921884f0db33fc2bf8d9fd",
        license = "LICENSE",
    },
    {
        name = "Luau",
        path = root .. "/vendor/Luau",
        revision = "caee04d82d014ed104dd63edec1710fb6ab5794c",
        license = "LICENSE.txt",
    },
}

local failures = 0

local function fail(message)
    io.write("FAIL: " .. message .. "\n")
    failures = failures + 1
end

local function check(message, condition)
    if condition then
        io.write("PASS: " .. message .. "\n")
    else
        fail(message)
    end
end

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then
        return nil
    end
    local contents = file:read("*a")
    file:close()
    return contents
end

local function checked_out_revision(path)
    -- rev-parse only reads Git metadata. It does not contact a remote or run
    -- hooks/build steps, and no file from the submodule is executed.
    local command = 'git -C "' .. path .. '" rev-parse --verify HEAD 2>&1'
    local pipe = io.popen(command, "r")
    if not pipe then
        return nil
    end
    local output = pipe:read("*a") or ""
    pipe:close()
    return output:match("([0-9a-fA-F]+)")
end

io.write("Offline vendor license/dependency verification\n")
io.write("Network access: none; vendor code execution: none\n")

local notices = read_file(notices_path)
check("required notice file exists: THIRD_PARTY_NOTICES.md", notices ~= nil)

for _, vendor in ipairs(vendors) do
    local revision = checked_out_revision(vendor.path)
    check(vendor.name .. " submodule exists", revision ~= nil)
    check(vendor.name .. " revision is " .. vendor.revision, revision == vendor.revision)
    check(vendor.name .. " license exists: " .. vendor.license,
        read_file(vendor.path .. "/" .. vendor.license) ~= nil)
end

local required_notice_entries = {
    "`vendor/Fiu`",
    "`vendor/Luau`",
    "Copyright (c) 2022-2024 TheGreatSageEqualToHeaven",
    "Copyright (c) 2019-2024 Roblox Corporation",
    "Copyright (c) 1994-2019 Lua.org, PUC-Rio.",
}

for _, entry in ipairs(required_notice_entries) do
    check("required third-party notice entry: " .. entry,
        notices ~= nil and notices:find(entry, 1, true) ~= nil)
end

if failures == 0 then
    io.write("RESULT: PASS (all checks succeeded)\n")
    os.exit(0)
end

io.write("RESULT: FAIL (" .. failures .. " check(s) failed)\n")
os.exit(1)
