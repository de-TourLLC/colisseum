-- Opaque native Luau bytecode boundary for the pinned Luau revision.
-- This module never parses, evaluates, or loads the payload itself.
local Transform = {}

Transform.MAGIC = "CLUB"
Transform.VERSION = 1
Transform.PINNED_REVISION = "caee04d82d014ed104dd63edec1710fb6ab5794c"
Transform.LIMITS = {
    payload = 64 * 1024 * 1024,
    metadata = 4096,
}

local UINT32 = 4294967296

local function failure(message)
    return nil, "luau-bytecode: " .. message
end

local function require_string(value, name, allow_empty)
    if type(value) ~= "string" or (not allow_empty and value == "") then
        return failure(name .. " must be " .. (allow_empty and "a string" or "a non-empty string"))
    end
    return value
end

local function u8(value)
    return string.char(value)
end

local function u32(value)
    return string.char(
        math.floor(value / 16777216) % 256,
        math.floor(value / 65536) % 256,
        math.floor(value / 256) % 256,
        value % 256
    )
end

local function read(data, position, size)
    if position + size - 1 > #data then
        return nil, nil, "truncated container"
    end
    local value = 0
    for index = position, position + size - 1 do
        value = value * 256 + data:byte(index)
    end
    return value, position + size
end

-- A small deterministic integrity check that works on Lua 5.1/LuaJIT too.
local function checksum(data)
    local value = 2166136261
    for index = 1, #data do
        value = (value * 65599 + data:byte(index)) % UINT32
    end
    return value
end

local function validate_options(options)
    if options == nil then return {} end
    if type(options) ~= "table" then return failure("options must be a table") end
    return options
end

local function validate_payload(payload)
    local value, message = require_string(payload, "bytecode payload", false)
    if not value then return nil, message end
    if #value > Transform.LIMITS.payload then
        return failure("bytecode payload exceeds size limit")
    end
    return value
end

local function validate_revision(revision)
    if revision ~= Transform.PINNED_REVISION then
        return failure("unsupported Luau revision " .. tostring(revision))
    end
    return revision
end

function Transform.metadata()
    return {
        format = "opaque-luau-bytecode-container",
        format_version = Transform.VERSION,
        luau_revision = Transform.PINNED_REVISION,
        payload_is_opaque = true,
        supports_native_decode = false,
    }
end

function Transform.capabilities(hooks)
    hooks = hooks or {}
    if type(hooks) ~= "table" then
        return { compile = false, decode = false, transform = false }
    end
    local compiler = hooks.compiler or hooks.compile
    local decoder = hooks.decoder or hooks.decode
    local transformer = hooks.transformer or hooks.transform
    local encoder = hooks.encoder or hooks.encode
    return {
        compile = type(compiler) == "function",
        decode = type(decoder) == "function",
        transform = type(decoder) == "function" and type(transformer) == "function"
            and type(encoder) == "function",
    }
end

function Transform.encode(payload, revision)
    local value, message = validate_payload(payload)
    if not value then return nil, message end
    revision = revision or Transform.PINNED_REVISION
    local valid_revision
    valid_revision, message = validate_revision(revision)
    if not valid_revision then return nil, message end
    local body = valid_revision .. value
    return Transform.MAGIC .. u8(Transform.VERSION) .. u8(0) .. u8(#valid_revision)
        .. u32(#value) .. u32(checksum(body)) .. body
end

function Transform.decode_container(container)
    local data, message = require_string(container, "container", false)
    if not data then return nil, message end
    if #data > Transform.LIMITS.payload + 64 then return failure("container exceeds size limit") end
    if data:sub(1, 4) ~= Transform.MAGIC then return failure("bad container magic") end

    local position = 5
    local version, flags, revision_length, payload_length, expected
    version, position, message = read(data, position, 1); if not version then return failure(message) end
    flags, position, message = read(data, position, 1); if not flags then return failure(message) end
    revision_length, position, message = read(data, position, 1); if not revision_length then return failure(message) end
    payload_length, position, message = read(data, position, 4); if not payload_length then return failure(message) end
    expected, position, message = read(data, position, 4); if not expected then return failure(message) end

    if version ~= Transform.VERSION then return failure("unsupported container version " .. version) end
    if flags ~= 0 then return failure("unsupported container flags") end
    if revision_length ~= #Transform.PINNED_REVISION then return failure("invalid revision length") end
    if payload_length > Transform.LIMITS.payload then return failure("bytecode payload exceeds size limit") end
    if position + revision_length + payload_length - 1 ~= #data then
        return failure("container length mismatch or trailing bytes")
    end

    local revision = data:sub(position, position + revision_length - 1)
    position = position + revision_length
    local payload = data:sub(position, position + payload_length - 1)
    local valid_revision
    valid_revision, message = validate_revision(revision)
    if not valid_revision then return nil, message end
    if checksum(revision .. payload) ~= expected then return failure("checksum mismatch") end
    return {
        payload = payload,
        revision = revision,
        bytes = payload_length,
        checksum = expected,
        format_version = version,
    }
end

function Transform.compile(source, hooks, options)
    local text, message = require_string(source, "source", false)
    if not text then return nil, message end
    options, message = validate_options(options)
    if not options then return nil, message end
    hooks = hooks or {}
    local compiler = type(hooks) == "table" and (hooks.compiler or hooks.compile) or nil
    if type(compiler) ~= "function" then return failure("unsupported: no external Luau compiler hook") end
    local payload, compiler_error = compiler(text, Transform.PINNED_REVISION, options)
    if type(payload) ~= "string" or payload == "" then
        return failure("external compiler returned invalid bytecode: " .. tostring(compiler_error or payload))
    end
    return Transform.encode(payload)
end

function Transform.decode(container, hooks, options)
    local record, message = Transform.decode_container(container)
    if not record then return nil, message end
    hooks = hooks or {}
    local decoder = type(hooks) == "table" and (hooks.decoder or hooks.decode) or nil
    if type(decoder) ~= "function" then return failure("unsupported: no external Luau decoder hook") end
    return decoder(record.payload, record.revision, options or {})
end

function Transform.transform(container, hooks, options)
    local record, message = Transform.decode_container(container)
    if not record then return nil, message end
    hooks = hooks or {}
    local decoder = type(hooks) == "table" and (hooks.decoder or hooks.decode) or nil
    local transformer = type(hooks) == "table" and (hooks.transformer or hooks.transform) or nil
    local encoder = type(hooks) == "table" and (hooks.encoder or hooks.encode) or nil
    if type(decoder) ~= "function" or type(transformer) ~= "function" or type(encoder) ~= "function" then
        return failure("unsupported: transform requires external decoder, transformer, and encoder hooks")
    end
    local decoded, decode_error = decoder(record.payload, record.revision, options or {})
    if decoded == nil then return failure("external decoder failed: " .. tostring(decode_error)) end
    local changed, transform_error = transformer(decoded, record.revision, options or {})
    if changed == nil then return failure("external transformer failed: " .. tostring(transform_error)) end
    local payload, encode_error = encoder(changed, record.revision, options or {})
    if type(payload) ~= "string" or payload == "" then
        return failure("external encoder returned invalid bytecode: " .. tostring(encode_error or payload))
    end
    return Transform.encode(payload)
end

return Transform
