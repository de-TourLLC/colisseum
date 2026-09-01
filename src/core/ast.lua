local Ast = {}

local node_kinds = {
    chunk = true, group = true, table = true, field = true,
    number = true, string = true, literal = true, identifier = true,
    member = true, index = true, call = true, unary = true, binary = true,
    expression = true, assign = true, ["local"] = true, ["return"] = true,
    ["function"] = true, ["function-expression"] = true,
    ["anonymous-function"] = true, ["for"] = true, ["repeat"] = true,
    ["if"] = true, ["while"] = true, ["do"] = true,
    forin = true, vararg = true, keyfield = true, massign = true,
    ["break"] = true
}

local child_fields = {
    chunk = { "body" },
    group = { "value" },
    table = { "values" },
    field = { "value" },
    member = { "object" },
    index = { "object", "key" },
    call = { "callee", "arguments" },
    unary = { "value" },
    binary = { "left", "right" },
    expression = { "value" },
    assign = { "target", "value" },
    ["local"] = { "values" },
    ["return"] = { "values" },
    ["function"] = { "body" },
    ["function-expression"] = { "body" },
    ["anonymous-function"] = { "body" },
    ["for"] = { "initial", "limit", "step", "body" },
    forin = { "exprs", "body" },
    keyfield = { "key", "value" },
    massign = { "targets", "values" },
    vararg = {},
    ["break"] = {},
    ["repeat"] = { "body", "condition" },
    ["if"] = { "branches", "fallback" },
    ["while"] = { "condition", "body" },
    ["do"] = { "body" }
}

local required_fields = {
    chunk = { body = "table" },
    group = { value = "node" },
    field = { value = "node" },
    member = { object = "node", name = "string" },
    index = { object = "node", key = "node" },
    call = { callee = "node", arguments = "table" },
    unary = { value = "node", operator = "string" },
    binary = { left = "node", right = "node", operator = "string" },
    expression = { value = "node" },
    assign = { target = "node", value = "node" },
    ["local"] = { names = "table", values = "table" },
    ["return"] = { values = "table" },
    ["function"] = { parameters = "table", body = "table" },
    ["function-expression"] = { parameters = "table", body = "table" },
    ["anonymous-function"] = { parameters = "table", body = "table" },
    ["for"] = { name = "string", initial = "node", limit = "node", body = "table" },
    forin = { names = "table", exprs = "table", body = "table" },
    keyfield = { key = "node", value = "node" },
    massign = { targets = "table", values = "table" },
    vararg = {},
    ["break"] = {},
    ["repeat"] = { body = "table", condition = "node" },
    ["if"] = { branches = "table" },
    ["while"] = { condition = "node", body = "table" },
    ["do"] = { body = "table" }
}

local function is_node(value)
    return type(value) == "table" and node_kinds[value.kind] == true
end

local function check_field(value, expected)
    if expected == "node" then return is_node(value) end
    return type(value) == expected
end

local function each_child(node, callback)
    for _, field in ipairs(child_fields[node.kind] or {}) do
        local value = node[field]
        if field == "branches" then
            for index, branch in ipairs(value or {}) do
                if type(branch) == "table" then
                    callback(branch.condition, field .. "[" .. index .. "].condition")
                    for child_index, child in ipairs(branch.body or {}) do
                        callback(child, field .. "[" .. index .. "].body[" .. child_index .. "]")
                    end
                end
            end
        elseif is_node(value) then
            callback(value, field)
        elseif type(value) == "table" then
            for index, child in ipairs(value) do
                callback(child, field .. "[" .. index .. "]")
            end
        end
    end
end

local function validate_node(node, path, seen)
    if not is_node(node) then return false, path .. ": expected AST node" end
    if seen[node] then return true end
    seen[node] = true

    local fields = required_fields[node.kind]
    if fields then
        for name, expected in pairs(fields) do
            if node[name] == nil then
                return false, path .. "." .. name .. ": missing " .. expected
            end
            if not check_field(node[name], expected) then
                return false, path .. "." .. name .. ": expected " .. expected
            end
        end
    end

    local failed, message = false, nil
    each_child(node, function(child, child_path)
        if failed or not is_node(child) then return end
        local valid
        valid, message = validate_node(child, path .. "." .. child_path, seen)
        failed = not valid
    end)
    if failed then return false, message end
    return true
end

function Ast.is_node(value)
    return is_node(value)
end

function Ast.validate_node(node)
    return validate_node(node, "root", {})
end

Ast.validate = Ast.validate_node
Ast.is_valid_node = function(node)
    local valid = Ast.validate_node(node)
    return valid
end

function Ast.walk(root, visitor)
    if type(visitor) ~= "function" then error("ast: visitor must be a function") end
    local seen = {}
    local function visit(node, parent, key)
        if not is_node(node) or seen[node] then return end
        seen[node] = true
        visitor(node, parent, key)
        each_child(node, function(child, child_key) visit(child, node, child_key) end)
    end
    visit(root)
end

function Ast.is_anonymous_function(node)
    if not is_node(node) then return false end
    return node.kind == "function-expression" or node.kind == "anonymous-function" or
        (node.kind == "function" and (node.anonymous == true or node.name == nil))
end

Ast.is_anonymous = Ast.is_anonymous_function

function Ast.is_closure(node, function_depth)
    if not is_node(node) or not (node.kind == "function" or Ast.is_anonymous_function(node)) then return false end
    return (function_depth or 0) > 0
end

function Ast.find_closures(root)
    local result = {}
    local function visit(node, depth)
        if not is_node(node) then return end
        local is_function = node.kind == "function" or Ast.is_anonymous_function(node)
        if is_function and depth > 0 then result[#result + 1] = node end
        local child_depth = is_function and depth + 1 or depth
        each_child(node, function(child) visit(child, child_depth) end)
    end
    visit(root, 0)
    return result
end

Ast.collect_closures = Ast.find_closures

function Ast.assign_scope_ids(root, start)
    local next_id = tonumber(start) or 1
    local scopes = {}
    Ast.walk(root, function(node)
        local scoped = node.kind == "chunk" or node.kind == "function" or
            Ast.is_anonymous_function(node) or node.kind == "for" or
            node.kind == "repeat" or node.kind == "do" or
            node.kind == "if" or node.kind == "while"
        if scoped then
            node.scope_id = next_id
            scopes[next_id] = node
            next_id = next_id + 1
        end
    end)
    return scopes, next_id - 1
end

Ast.scope_ids = Ast.assign_scope_ids

return Ast
