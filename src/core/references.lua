local References = {}

local function new_scope(parent, kind, owner)
    local scope = {
        parent = parent,
        kind = kind,
        owner = owner,
        children = {},
        declarations = {},
        symbols = {},
        unresolved = {},
        upvalues = {},
        upvalue_symbols = {}
    }
    if parent then parent.children[#parent.children + 1] = scope end
    return scope
end

local function declare(scope, name, kind, position, node)
    local symbol = {
        name = name,
        kind = kind,
        scope = scope,
        position = position or 0,
        node = node,
        references = {},
        references_count = 0,
        upvalues = {}
    }
    local list = scope.symbols[name]
    if not list then
        list = {}
        scope.symbols[name] = list
    end
    list[#list + 1] = symbol
    scope.declarations[#scope.declarations + 1] = symbol
    return symbol
end

local function find(scope, name, position)
    while scope do
        local list = scope.symbols[name]
        if list then
            for index = #list, 1, -1 do
                if list[index].position < position then return list[index] end
            end
        end
        scope = scope.parent
    end
end

local function function_scope(scope)
    while scope and scope.kind ~= "function" do scope = scope.parent end
    return scope
end

local function root_scope(scope)
    while scope and scope.parent do scope = scope.parent end
    return scope
end

local function is_upvalue(symbol, reference_scope)
    local reference_function = function_scope(reference_scope)
    local symbol_function = function_scope(symbol.scope)
    return reference_function and reference_function ~= symbol_function and symbol_function ~= nil
end

local walk_expression
local walk_body

local function reference(node, scope)
    local symbol = find(scope, node.value, node.start or math.huge)
    node.binding = symbol
    node.reference = symbol
    if not symbol then
        node.unresolved = true
        scope.unresolved[#scope.unresolved + 1] = node
        local root = root_scope(scope)
        if root ~= scope then root.unresolved[#root.unresolved + 1] = node end
        return
    end
    symbol.references[#symbol.references + 1] = node
    symbol.references_count = symbol.references_count + 1
    if is_upvalue(symbol, scope) then
        node.upvalue = true
        local owner = function_scope(scope)
        symbol.upvalues[owner] = true
        if not owner.upvalue_symbols[symbol] then
            owner.upvalue_symbols[symbol] = true
            owner.upvalues[#owner.upvalues + 1] = symbol
        end
    end
end

walk_expression = function(value, scope)
    if not value then return end
    if value.kind == "identifier" then
        reference(value, scope)
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
            if field.kind == "field" then walk_expression(field.value, scope)
            else walk_expression(field, scope) end
        end
    end
end

local function walk_function(statement, parent)
    local scope = new_scope(parent, "function", statement)
    statement.scope = scope
    for _, name in ipairs(statement.parameters) do
        declare(scope, name, "parameter", statement.start, statement)
    end
    walk_body(statement.body, scope)
end

local function walk_statement(statement, scope)
    statement.scope = scope
    if statement.kind == "local" then
        -- Initializers run before the new locals become visible.
        for _, value in ipairs(statement.values) do walk_expression(value, scope) end
        for _, name in ipairs(statement.names) do
            declare(scope, name, "local", statement.start, statement)
        end
    elseif statement.kind == "function" then
        local symbol = declare(scope, statement.name,
            statement.local_function and "local-function" or "function",
            statement.start, statement)
        statement.binding = symbol
        walk_function(statement, scope)
    elseif statement.kind == "for" then
        walk_expression(statement.initial, scope)
        walk_expression(statement.limit, scope)
        walk_expression(statement.step, scope)
        local loop = new_scope(scope, "for", statement)
        statement.scope = loop
        declare(loop, statement.name, "for-variable", statement.start, statement)
        walk_body(statement.body, loop)
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
            local branch_scope = new_scope(scope, "block", statement)
            walk_body(branch.body, branch_scope)
        end
        if statement.fallback then
            local fallback_scope = new_scope(scope, "block", statement)
            walk_body(statement.fallback, fallback_scope)
        end
    elseif statement.kind == "while" then
        walk_expression(statement.condition, scope)
        local body_scope = new_scope(scope, "block", statement)
        walk_body(statement.body, body_scope)
    elseif statement.kind == "do" then
        local body_scope = new_scope(scope, "block", statement)
        statement.scope = body_scope
        walk_body(statement.body, body_scope)
    elseif statement.kind == "repeat" then
        local repeat_scope = new_scope(scope, "repeat", statement)
        statement.scope = repeat_scope
        walk_body(statement.body, repeat_scope)
        walk_expression(statement.condition, repeat_scope)
    end
end

walk_body = function(body, scope)
    for _, statement in ipairs(body) do walk_statement(statement, scope) end
end

function References.find(scope, name, position)
    if not scope or type(name) ~= "string" then return nil end
    return find(scope, name, position or math.huge)
end

function References.analyze(ast)
    if type(ast) ~= "table" or ast.kind ~= "chunk" then
        error("references: expected chunk AST")
    end
    local root = new_scope(nil, "root", ast)
    root.ast = ast
    walk_body(ast.body, root)
    return root
end

return References
