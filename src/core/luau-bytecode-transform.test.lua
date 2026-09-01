local Transform = require("src.core.luau-bytecode-transform")

local function expect_error(callback, fragment)
    local value, message = callback()
    assert(value == nil, "expected operation to fail")
    assert(type(message) == "string" and message:find(fragment, 1, true), message)
end

expect_error(function()
    return Transform.compile("return 1", {})
end, "unsupported: no external Luau compiler hook")

local compiler_revision
local compiler_options
local compiled = assert(Transform.compile("return 1", {
    compiler = function(source, revision, options)
        assert(source == "return 1")
        compiler_revision = revision
        compiler_options = options
        return "native-bytecode"
    end,
}, { optimize = false }))
assert(compiler_revision == Transform.PINNED_REVISION)
assert(compiler_options.optimize == false)
assert(Transform.decode_container(compiled).payload == "native-bytecode")

expect_error(function()
    return Transform.transform(compiled, {})
end, "unsupported: transform requires external decoder")

local container = assert(Transform.encode("opaque-bytecode"))
local record = assert(Transform.decode_container(container))
assert(record.payload == "opaque-bytecode")
assert(record.revision == Transform.PINNED_REVISION)

expect_error(function()
    return Transform.decode_container(container:sub(1, -2))
end, "length mismatch")

local corrupted = container:sub(1, -2) .. string.char((container:byte(#container) + 1) % 256)
expect_error(function()
    return Transform.decode_container(corrupted)
end, "checksum mismatch")

expect_error(function()
    return Transform.decode("not-a-container", {})
end, "bad container magic")

return true
