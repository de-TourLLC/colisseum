-- Shared LuaJIT-compatible benchmark helpers and bounded fixtures.

local Common = {}

Common.source = [[
-- Fixed benchmark fixture: arithmetic, a table, and bounded control flow.
local values = { 3, 5, 8, 13, label = "fixture" }
local total = 0
for index = 1, 24 do
    total = total + index * 3
end
return total + values[2]
]]

function Common.measure(label, iterations, operation)
    for _ = 1, 2 do operation() end
    collectgarbage("collect")
    local before = collectgarbage("count")
    local started = os.clock()
    local result
    for _ = 1, iterations do result = operation() end
    local elapsed = os.clock() - started
    local after = collectgarbage("count")
    local milliseconds = elapsed * 1000 / iterations
    local memory = after - before
    print(string.format("%-28s %8.3f ms/op  %8.2f KB delta  (%d iterations)",
        label, milliseconds, memory, iterations))
    return result
end

function Common.header(title)
    print(title)
    print(string.rep("-", #title))
end

return Common
