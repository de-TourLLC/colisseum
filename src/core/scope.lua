local Scope = {}

local function create(parent, kind)
    return { parent = parent, kind = kind, symbols = {}, children = {} }
end

local function declare(scope, name, kind)
    local symbol = scope.symbols[name]
    if not symbol then
        symbol = { name = name, kind = kind, scope = scope, references = 0 }
        scope.symbols[name] = symbol
    end
    return symbol
end

local function walk_expression(value, scope)
    if not value then return end
    if value.kind == "identifier" then
        local current = scope
        while current and not current.symbols[value.value] do current = current.parent end
        if current then current.symbols[value.value].references = current.symbols[value.value].references + 1 end
    elseif value.kind == "binary" then
        walk_expression(value.left, scope)
        walk_expression(value.right, scope)
    elseif value.kind == "unary" or value.kind == "group" then
        walk_expression(value.value, scope)
    elseif value.kind == "member" then
        walk_expression(value.object, scope)
    elseif value.kind == "index" then
        walk_expression(value.object, scope)
        walk_expression(value.key, scope)
    elseif value.kind == "call" then
        walk_expression(value.callee, scope)
        for _, argument in ipairs(value.arguments) do walk_expression(argument, scope) end
    elseif value.kind == "table" then
        for _, field in ipairs(value.values) do
            if field.kind == "field" then walk_expression(field.value, scope) else walk_expression(field, scope) end
        end
    end
end

local function walk_block(body, parent)
    local scope = create(parent, "block")
    parent.children[#parent.children + 1] = scope
    for _, statement in ipairs(body) do
        if statement.kind == "local" then
            for _, name in ipairs(statement.names) do declare(scope, name, "local") end
            for _, value in ipairs(statement.values) do walk_expression(value, scope) end
        elseif statement.kind == "function" then
            declare(scope, statement.name, statement.local_function and "local-function" or "function")
            local function_scope = create(scope, "function")
            scope.children[#scope.children + 1] = function_scope
            for _, name in ipairs(statement.parameters) do declare(function_scope, name, "parameter") end
            for _, child in ipairs(statement.body) do walk_block({ child }, function_scope) end
        elseif statement.kind == "return" then
            for _, value in ipairs(statement.values) do walk_expression(value, scope) end
        elseif statement.kind == "assign" then
            walk_expression(statement.target, scope)
            walk_expression(statement.value, scope)
        elseif statement.kind == "expression" then
            walk_expression(statement.value, scope)
        elseif statement.kind == "if" then
            for _, branch in ipairs(statement.branches) do
                walk_expression(branch.condition, scope)
                walk_block(branch.body, scope)
            end
            if statement.fallback then walk_block(statement.fallback, scope) end
        elseif statement.kind == "while" then
            walk_expression(statement.condition, scope)
            walk_block(statement.body, scope)
        elseif statement.kind == "do" or statement.kind == "repeat" then
            walk_block(statement.body, scope)
            if statement.condition then walk_expression(statement.condition, scope) end
        elseif statement.kind == "for" then
            walk_expression(statement.initial, scope)
            walk_expression(statement.limit, scope)
            walk_expression(statement.step, scope)
            local loop = create(scope, "for")
            scope.children[#scope.children + 1] = loop
            declare(loop, statement.name, "for-variable")
            for _, child in ipairs(statement.body) do walk_block({ child }, loop) end
        end
    end
    return scope
end

function Scope.analyze(ast)
    if type(ast) ~= "table" or ast.kind ~= "chunk" then error("scope: expected chunk AST") end
    local root = create(nil, "root")
    walk_block(ast.body, root)
    return root
end

return Scope
