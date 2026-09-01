local total = 7 * 6
local function adjust(value)
    return value + 5
end
return adjust(total), total == 42, 2 ^ 3
