local Registry = {}
Registry.__index = Registry

local function fail(message)
    error("step registry: " .. message, 3)
end

local function copy_metadata(metadata)
    local copy = {}
    for key, value in pairs(metadata) do
        if key ~= "dependencies" then copy[key] = value end
    end
    copy.dependencies = {}
    for index, dependency in ipairs(metadata.dependencies) do
        copy.dependencies[index] = dependency
    end
    return copy
end

local function is_array(value)
    local count = 0
    for key in pairs(value) do
        if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then return false end
        count = count + 1
    end
    for index = 1, count do
        if value[index] == nil then return false end
    end
    return true
end

local function validate_metadata(metadata)
    if type(metadata) ~= "table" then fail("metadata must be a table") end
    local id = metadata.id
    if type(id) ~= "string" or not id:match("^[%a][%w%-]*$") then
        fail("metadata id must be an English identifier")
    end
    if type(metadata.module) ~= "string" or metadata.module == "" then
        fail("step " .. id .. " must declare a module")
    end
    if type(metadata.version) ~= "number" or metadata.version < 1 or metadata.version % 1 ~= 0 then
        fail("step " .. id .. " must declare a positive integer version")
    end
    if type(metadata.description) ~= "string" or metadata.description == "" then
        fail("step " .. id .. " must declare an English description")
    end
    if type(metadata.dependencies) ~= "table" or not is_array(metadata.dependencies) then
        fail("step " .. id .. " dependencies must be an array")
    end
    local seen = {}
    for index, dependency in ipairs(metadata.dependencies) do
        if type(dependency) ~= "string" or not dependency:match("^[%a][%w%-]*$") then
            fail("step " .. id .. " has an invalid dependency at index " .. index)
        end
        if dependency == id then fail("step " .. id .. " cannot depend on itself") end
        if seen[dependency] then fail("step " .. id .. " declares dependency " .. dependency .. " twice") end
        seen[dependency] = true
    end
    return true
end

function Registry.new(definitions)
    local registry = setmetatable({ entries = {}, modules = {} }, Registry)
    if definitions ~= nil then
        if type(definitions) ~= "table" then fail("catalog must be an array") end
        for index, metadata in ipairs(definitions) do
            registry:register(metadata)
        end
        if not is_array(definitions) then fail("catalog must be a contiguous array") end
    end
    return registry
end

function Registry:register(metadata)
    validate_metadata(metadata)
    if self.entries[metadata.id] then fail("duplicate step id " .. metadata.id) end
    self.entries[metadata.id] = copy_metadata(metadata)
    return self.entries[metadata.id]
end

function Registry:get(id)
    if type(id) ~= "string" then return nil end
    return self.entries[id]
end

function Registry:ids()
    local ids = {}
    for id in pairs(self.entries) do ids[#ids + 1] = id end
    table.sort(ids)
    return ids
end

function Registry:validate()
    for _, id in ipairs(self:ids()) do
        local metadata = self.entries[id]
        for _, dependency in ipairs(metadata.dependencies) do
            if not self.entries[dependency] then
                fail("step " .. id .. " depends on unknown step " .. dependency)
            end
        end
        local ok, module = pcall(require, metadata.module)
        if not ok then fail("cannot load step " .. id .. ": " .. tostring(module)) end
        if type(module) ~= "table" or type(module.apply) ~= "function" then
            fail("step " .. id .. " module must export an apply function")
        end
        if module.name ~= id then fail("step " .. id .. " module name does not match metadata") end
        if module.version ~= metadata.version then fail("step " .. id .. " module version does not match metadata") end
        self.modules[id] = module
    end
    self:ordered()
    return true
end

function Registry:load(id)
    local metadata = self.entries[id]
    if not metadata then fail("unknown step " .. tostring(id)) end
    if not self.modules[id] then self:validate() end
    return self.modules[id]
end

function Registry:ordered(requested)
    local selected = {}
    if requested == nil then
        for id in pairs(self.entries) do selected[id] = true end
    else
        if type(requested) ~= "table" or not is_array(requested) then fail("ordered steps must be an array") end
        for index, id in ipairs(requested) do
            if type(id) ~= "string" or not self.entries[id] then
                fail("ordered steps contain unknown step " .. tostring(id) .. " at index " .. index)
            end
            selected[id] = true
        end
    end

    local visiting, visited, result = {}, {}, {}
    local function visit(id)
        if visiting[id] then fail("dependency cycle includes " .. id) end
        if visited[id] then return end
        visiting[id] = true
        local dependencies = self.entries[id].dependencies
        local sorted = {}
        for _, dependency in ipairs(dependencies) do sorted[#sorted + 1] = dependency end
        table.sort(sorted)
        for _, dependency in ipairs(sorted) do
            if not self.entries[dependency] then fail("step " .. id .. " depends on unknown step " .. dependency) end
            selected[dependency] = true
            visit(dependency)
        end
        visiting[id] = nil
        visited[id] = true
        result[#result + 1] = self.entries[id]
    end
    local ids = {}
    for id in pairs(selected) do ids[#ids + 1] = id end
    table.sort(ids)
    for _, id in ipairs(ids) do visit(id) end
    return result
end

return Registry
