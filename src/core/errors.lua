local Errors = {}

local function text(value)
    value = tostring(value)
    if value:sub(1, 10) == "colisseum:" then return value end
    return "colisseum: " .. value
end

function Errors.message(value)
    return text(value)
end

function Errors.raise(value, level)
    error(text(value), (level or 1) + 1)
end

function Errors.handler(value)
    return text(value)
end

function Errors.protect(callback, ...)
    if type(callback) ~= "function" then return nil, text("callback must be a function") end
    local arguments = { ... }
    local unpack_values = table.unpack or unpack
    local result = { xpcall(function() return callback(unpack_values(arguments)) end, Errors.handler) }
    local ok = table.remove(result, 1)
    if not ok then return nil, result[1] end
    return unpack_values(result)
end

return Errors
