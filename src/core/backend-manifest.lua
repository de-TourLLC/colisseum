-- Read-only capability discovery for the production Luau backend.
-- This module deliberately never loadfile's or executes a backend/source file.
local Manifest = {}

Manifest.pinned = {
    luau = "caee04d82d014ed104dd63edec1710fb6ab5794c",
    fiu = "0acebaccc8aa072113921884f0db33fc2bf8d9fd",
}

local is_windows = package.config:sub(1, 1) == "\\"
local path_separator = is_windows and "\\" or "/"

local function read_file(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local value = file:read("*a")
    file:close()
    return value
end

local function file_available(path)
    local file = io.open(path, "rb")
    if not file then return false end
    local value = file:read(1)
    file:close()
    return value ~= nil
end

local function join(left, right)
    if left:sub(-1) == "/" or left:sub(-1) == "\\" then
        return left .. right
    end
    return left .. path_separator .. right
end

local function trim(value)
    return (value:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function valid_path(value, name)
    if type(value) ~= "string" or value == "" then
        return nil, name .. " must be a non-empty string"
    end
    if value:find("%z") or value:find("[\r\n]") then
        return nil, name .. " contains an invalid control character"
    end
    return value
end

local function path_has_directory(value)
    return value:find("[/\\]", 1) ~= nil or value:match("^%a:") ~= nil
end

local function executable_candidates(path)
    local candidates = { path }
    if is_windows and not path:match("%.[^\\/]+$") then
        local extensions = os.getenv("PATHEXT") or ".COM;.EXE;.BAT;.CMD"
        for extension in extensions:gmatch("[^;]+") do
            candidates[#candidates + 1] = path .. extension
        end
    end
    return candidates
end

local function resolve_executable(requested)
    local path, message = valid_path(requested, "compiler executable path")
    if not path then return nil, message end

    if path_has_directory(path) then
        for _, candidate in ipairs(executable_candidates(path)) do
            if file_available(candidate) then return candidate end
        end
        return nil, "compiler executable was not found at " .. path
    end

    local search_path = os.getenv("PATH") or ""
    local separator = is_windows and ";" or ":"
    for directory in search_path:gmatch("[^" .. separator .. "]+") do
        for _, candidate in ipairs(executable_candidates(join(directory, path))) do
            if file_available(candidate) then return candidate end
        end
    end
    return nil, "compiler executable was not found in PATH: " .. path
end

local function git_revision(directory)
    local git_entry = read_file(join(directory, ".git"))
    if not git_entry then return nil end
    local git_directory = trim(git_entry):match("^gitdir:%s*(.+)$")
    if not git_directory then return nil end

    local head = read_file(join(directory, git_directory .. "/HEAD"))
    if not head then return nil end
    head = trim(head)
    local reference = head:match("^ref:%s*(.+)$")
    if reference then
        head = read_file(join(directory, git_directory .. "/" .. reference))
        if not head then return nil end
        head = trim(head)
    end
    if not head:match("^[0-9a-fA-F]+$") then return nil end
    return head:lower()
end

local function source_status(root, name, relative_files, expected_revision)
    local directory = join(root, "vendor" .. path_separator .. name)
    local missing = {}
    for _, relative in ipairs(relative_files) do
        if not file_available(join(directory, relative)) then
            missing[#missing + 1] = relative
        end
    end

    local revision = git_revision(directory)
    local revision_pinned = revision == expected_revision
    local available = #missing == 0 and revision ~= nil
    local status = available and (revision_pinned and "ready" or "revision-mismatch") or "unavailable"
    return {
        name = name,
        path = directory,
        available = available,
        revision = revision,
        expected_revision = expected_revision,
        pinned = available and revision_pinned or false,
        missing = missing,
        status = status,
    }
end

local function compiler_status(compiler)
    if compiler == nil then
        return { available = false, status = "not-configured", message = "compiler executable path was not configured" }
    end
    local resolved, message = resolve_executable(compiler)
    return {
        requested = compiler,
        path = resolved,
        available = resolved ~= nil,
        status = resolved and "ready" or "unavailable",
        message = message,
    }
end

-- Returns a fresh manifest and performs filesystem inspection only.
function Manifest.inspect(options)
    options = options or {}
    if type(options) ~= "table" then
        return nil, "backend-manifest: options must be a table"
    end

    local source = debug.getinfo(1, "S").source:sub(2)
    local default_root = source:match("^(.*)[/\\]src[/\\]core[/\\][^/\\]+$") or "."
    local root = options.root or default_root
    local root_error
    root, root_error = valid_path(root, "project root")
    if not root then return nil, "backend-manifest: " .. root_error end

    local luau = source_status(root, "Luau", {
        "Compiler/include/luacode.h",
        "VM/include/lua.h",
    }, Manifest.pinned.luau)
    local fiu = source_status(root, "Fiu", {}, Manifest.pinned.fiu)
    local fiu_source = join(fiu.path, "Source.lua")
    local fiu_text = read_file(fiu_source)
    fiu.api = fiu_text ~= nil and fiu_text:find("luau_load", 1, true) ~= nil
        and fiu_text:find("luau_newsettings", 1, true) ~= nil
        and fiu_text:find("luau_deserialize", 1, true) ~= nil
    fiu.available = fiu.available and fiu.api
    if not fiu.available then fiu.status = "unavailable" end

    local compiler = compiler_status(options.compiler)
    local can_compile = luau.pinned and compiler.available
    local can_package = can_compile and fiu.pinned and fiu.api
    return {
        root = root,
        luau = luau,
        fiu = fiu,
        compiler = compiler,
        capabilities = {
            compile = { available = can_compile, status = can_compile and "ready" or "unavailable" },
            package = { available = can_package, status = can_package and "ready" or "unavailable" },
        },
        status = can_package and "package-ready" or (can_compile and "compile-ready" or "unavailable"),
    }
end

return Manifest
