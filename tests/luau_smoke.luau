local function check(value, message)
    if not value then error(message, 0) end
end

local total = 0
for index = 1, 10 do
    total += index
end

local function closure(value)
    return function(addition)
        return value + addition
    end
end

local result = closure(total)(5)
check(result == 60, "Luau smoke test failed")
print("Luau smoke test passed")
