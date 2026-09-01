-- Adapter for an external Luau compiler executable.
-- The process is invoked through the host Lua process API, so every argument
-- is validated and quoted before it reaches the platform command shell.
local Validate = require("src.core.validate")

local Compiler = {}

local is_windows = package.config:sub(1, 1) == "\\"
local shell_controls = "[&|<>^%%()!\r\n]"

local function error_message(message)
    return "luau-compiler: " .. message
end

local function valid_text(value, name)
    if type(value) ~= "string" or value == "" then
        return nil, error_message(name .. " must be a non-empty string")
    end
    if value:find("%z") or value:find("[\r\n]") then
        return nil, error_message(name .. " contains an invalid control character")
    end
    return value
end

-- Source is written to a temporary file and passed to the compiler by path, so
-- it never reaches the shell. It therefore may (and normally does) contain
-- newlines; only a null byte makes it invalid as a text source file.
local function valid_source(value)
    if type(value) ~= "string" or value == "" then
        return nil, error_message("source must be a non-empty string")
    end
    if value:find("%z") then
        return nil, error_message("source contains a null byte")
    end
    return value
end

local function quote_argument(value)
    if value:find(shell_controls) then
        return nil, error_message("argument contains shell control characters")
    end

    if is_windows then
        value = value:gsub("/", "\\")
        if not value:find("%s") then return value end
        -- CommandLineToArgvW-compatible quoting. Shell metacharacters were
        -- rejected above because cmd.exe still expands some of them in quotes.
        local quoted = { '"' }
        local slashes = 0
        for index = 1, #value do
            local character = value:sub(index, index)
            if character == "\\" then
                slashes = slashes + 1
            elseif character == '"' then
                quoted[#quoted + 1] = string.rep("\\", slashes * 2 + 1)
                quoted[#quoted + 1] = '"'
                slashes = 0
            else
                quoted[#quoted + 1] = string.rep("\\", slashes)
                quoted[#quoted + 1] = character
                slashes = 0
            end
        end
        quoted[#quoted + 1] = string.rep("\\", slashes * 2)
        quoted[#quoted + 1] = '"'
        return table.concat(quoted)
    end

    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function executable_status(path)
    local file = io.open(path, "rb")
    if not file then
        return false, error_message("compiler unavailable: executable was not found at " .. path)
    end
    file:close()
    return true
end

local function temporary_file(extension)
    local name = os.tmpname()
    if type(name) ~= "string" or name == "" then
        return nil, error_message("could not create a temporary file name")
    end
    name = name:match("[^/\\]+$") .. extension
    local file, message = io.open(name, "wb")
    if not file then
        return nil, error_message("could not create temporary file: " .. tostring(message))
    end
    file:close()
    return name
end

local function read_file(path)
    local file, message = io.open(path, "rb")
    if not file then return nil, message end
    local value = file:read("*a")
    file:close()
    return value
end

local function remove(path)
    if path then os.remove(path) end
end

-- Returns a status table and never starts the compiler.
function Compiler.dry_run(executable)
    local path, message = valid_text(executable, "compiler executable path")
    if not path then return { available = false, message = message } end
    local available, reason = executable_status(path)
    return { available = available, executable = path, message = reason }
end

Compiler.capability = Compiler.dry_run
function Compiler.available(executable)
    return Compiler.dry_run(executable).available
end

function Compiler.compile(source, executable, options)
    local text, message = valid_source(source)
    if not text then return nil, message end
    local path
    path, message = valid_text(executable, "compiler executable path")
    if not path then return nil, message end
    options = options or {}
    if type(options) ~= "table" then return nil, error_message("options must be a table") end

    local syntax_ok, syntax_message, position = Validate.syntax(text)
    if not syntax_ok then
        return nil, error_message("source syntax check failed at " .. tostring(position) .. ": " .. tostring(syntax_message))
    end

    local capability = Compiler.dry_run(path)
    if not capability.available then return nil, capability.message end
    if options.dry_run then return nil, capability.message or "luau-compiler: compiler is available" end

    local input, input_error = temporary_file(".luau")
    if not input then return nil, input_error end
    local output, output_error = temporary_file(".luau-bytecode")
    if not output then remove(input); return nil, output_error end
    local diagnostics, diagnostics_error = temporary_file(".stderr")
    if not diagnostics then remove(input); remove(output); return nil, diagnostics_error end

    local input_file = io.open(input, "wb")
    if not input_file then
        remove(input); remove(output); remove(diagnostics)
        return nil, error_message("could not write temporary source file")
    end
    input_file:write(text)
    input_file:close()

    local arguments = options.arguments or { "--binary", "-O2", "-g0", input }
    if type(arguments) ~= "table" then
        remove(input); remove(output); remove(diagnostics)
        return nil, error_message("options.arguments must be a table")
    end
    local command = { path }
    for index = 1, #arguments do
        local argument, argument_error = valid_text(tostring(arguments[index]), "compiler argument")
        if not argument then
            remove(input); remove(output); remove(diagnostics)
            return nil, argument_error
        end
        local quoted, quote_error = quote_argument(argument)
        if not quoted then
            remove(input); remove(output); remove(diagnostics)
            return nil, quote_error
        end
        command[#command + 1] = quoted
    end
    local quoted_path, path_error = quote_argument(path)
    if not quoted_path then
        remove(input); remove(output); remove(diagnostics)
        return nil, path_error
    end
    if is_windows and (path:lower():match("%.bat$") or path:lower():match("%.cmd$")) then
        command[1] = "call " .. quoted_path
    else
        command[1] = quoted_path
    end
    local quoted_diagnostics = quote_argument(diagnostics)
    local command_text = table.concat(command, " ") .. " > " .. output .. " 2> " .. diagnostics
    local status = os.execute(command_text)
    local successful = status == true or status == 0
    local result, read_error = successful and read_file(output) or nil
    local diagnostic_text = read_file(diagnostics)
    remove(input); remove(output); remove(diagnostics)

    if not successful then
        local detail = diagnostic_text and diagnostic_text:gsub("%s+$", "") or ""
        if detail == "" then detail = "compiler exited with status " .. tostring(status) end
        return nil, error_message("compiler failed: " .. detail .. " [command: " .. command_text .. "]")
    end
    if not result then return nil, error_message("compiler produced no readable bytecode: " .. tostring(read_error)) end
    if #result == 0 then return nil, error_message("compiler produced empty bytecode") end
    return result
end

return Compiler
