local Names = require("src.steps.naming.name-generator")
local Lexer = require("src.core.lexer")

local Step = {}
Step.name = "rename"
Step.version = 3

local reserved = {
    ["and"] = true, ["break"] = true, ["do"] = true, ["else"] = true, ["elseif"] = true, ["end"] = true,
    ["false"] = true, ["for"] = true, ["function"] = true, ["if"] = true, ["in"] = true, ["local"] = true,
    ["nil"] = true, ["not"] = true, ["or"] = true, ["repeat"] = true, ["return"] = true, ["then"] = true,
    ["true"] = true, ["until"] = true, ["while"] = true, ["continue"] = true, ["export"] = true,
    ["type"] = true, ["typeof"] = true
}

local function scope(parent, kind)
    return { parent = parent, kind = kind, bindings = {} }
end

local function find(scope_value, name)
    while scope_value do
        if scope_value.bindings[name] then return scope_value.bindings[name] end
        scope_value = scope_value.parent
    end
end

local function declaration(scope_value, name, generator, positions)
    if not scope_value.bindings[name] then
        scope_value.bindings[name] = { output = generator:next(), positions = positions }
    end
    return scope_value.bindings[name]
end

function Step.apply(source, options)
    if type(source) ~= "string" then error("rename: source must be a string") end
    options = options or {}
    local generator = Names.new(options.seed, options.naming)
    local tokens = Lexer.scan(source)
    local root = scope(nil, "root")
    local current = root
    local replacements = {}
    local declarations = {}
    local stack = {}
    local declaring = false
    local for_declaration = false
    local braces = 0
    local parameters = false
    local param_type = false
    local type_depth = 0
    local local_function = false
    local function_header = false
    -- repeat...until keeps its scope open through the condition (which sees the body's locals), so defer the pop until the condition ends.
    local repeat_condition = false
    local repeat_depth = 0
    -- `local x = <init>`: names aren't in scope in their own initializer, so
    -- `local print = print` must resolve the RHS to the outer/global binding.
    local in_local_rhs = false
    local is_local_decl = false
    local local_pending = {}
    local reserved_value = { ["true"] = true, ["false"] = true, ["nil"] = true }
    -- Tokens that continue an expression after a value; anything else after a value-ending token starts a new statement.
    local continuation = {
        ["+"] = true, ["-"] = true, ["*"] = true, ["/"] = true, ["%"] = true, ["^"] = true,
        [".."] = true, ["=="] = true, ["~="] = true, ["<"] = true, [">"] = true, ["<="] = true,
        [">="] = true, ["//"] = true, ["and"] = true, ["or"] = true, ["."] = true, [":"] = true,
        ["["] = true, ["("] = true, ["{"] = true, [","] = true, ["="] = true,
    }
    local function ends_value(tok)
        if not tok then return false end
        if tok.kind == "identifier" then return (not reserved[tok.value]) or reserved_value[tok.value] end
        if tok.kind == "number" or tok.kind == "string" then return true end
        local v = tok.value
        return v == ")" or v == "]" or v == "}" or v == "..." or v == "end"
    end
    local function push(kind)
        stack[#stack + 1] = current
        current = scope(current, kind)
    end
    local function pop()
        if #stack > 0 then current = table.remove(stack) end
    end
    local function previous(index)
        return tokens[index - 1]
    end
    local function next_token(index)
        return tokens[index + 1]
    end

    -- Tokens that can't appear in an expression; one at depth 0 after until <expr> means the block ended, so close the repeat scope first.
    local statement_boundary_keywords = {
        ["local"] = true, ["if"] = true, ["while"] = true, ["for"] = true,
        ["do"] = true, ["function"] = true, ["return"] = true, ["break"] = true,
        ["repeat"] = true, ["then"] = true, ["else"] = true, ["elseif"] = true,
        ["end"] = true, ["until"] = true, [";"] = true
    }
    local operand_end = {
        [")"] = true, ["]"] = true, ["}"] = true
    }

    for index, token in ipairs(tokens) do
        local value = token.value
        local before = previous(index)
        local after = next_token(index)
        -- Inside a repeat condition: once the expression ends, pop the repeat scope
        -- so the condition sees the body's locals and following code doesn't.
        if repeat_condition then
            if value == "(" or value == "[" or value == "{" then
                repeat_depth = repeat_depth + 1
            elseif value == ")" or value == "]" or value == "}" then
                repeat_depth = math.max(0, repeat_depth - 1)
            elseif repeat_depth == 0 then
                local operand_starts = (token.kind == "identifier" and not reserved[value])
                    or token.kind == "number" or token.kind == "string"
                local ended_by_keyword = statement_boundary_keywords[value]
                local followed_operand = before and
                    (before.kind == "number" or before.kind == "string"
                        or operand_end[before.value]
                        or (before.kind == "identifier" and not reserved[before.value]))
                if ended_by_keyword or (operand_starts and followed_operand) then
                    pop()
                    repeat_condition = false
                end
            end
        end
        -- A local's initializer ends when its value is complete and the next token starts a new statement; clearing here lets later uses resolve to the new locals. ; always ends it.
        if in_local_rhs and (value == ";"
            or (ends_value(before) and not continuation[value] and token.kind ~= "string")) then
            in_local_rhs = false
            local_pending = {}
        end
        if token.kind == "identifier" and not reserved[value] then
            local field = before and (before.value == "." or before.value == ":")
            local table_key = after and after.value == "=" and braces > 0
            if parameters then
                -- Declare real parameter names, but not identifiers inside a Luau type annotation (p: SomeType); binding a type name would rename later uses of it.
                if not param_type then
                    local binding = declaration(current, value, generator, declarations)
                    declarations[token.start] = binding
                end
            elseif local_function then
                -- local function f binds f in the current scope, then opens a new scope for its params and body so the closing end pops that inner one.
                local binding = declaration(current, value, generator, declarations)
                declarations[token.start] = binding
                push("function")
                local_function = false
                function_header = true
            elseif declaring or for_declaration then
                if not field then
                    -- Only newly-introduced names get the self-reference guard; a
                    -- re-declared/shadowed name keeps resolving to the prior binding.
                    local newly = is_local_decl and current.bindings[value] == nil
                    local binding = declaration(current, value, generator, declarations)
                    declarations[token.start] = binding
                    if newly then local_pending[value] = true end
                    declaring = after and after.value == ","
                    -- LHS of a `local ... = ...` just ended and an initializer follows:
                    -- enter RHS mode so self-references resolve to the outer scope.
                    if is_local_decl and not declaring and after and after.value == "=" then
                        in_local_rhs = true
                    end
                    for_declaration = false
                end
            elseif not field and not table_key then
                -- Inside a local initializer, a reference to a name declared by the same statement uses the outer binding (or a global), not the new local.
                local binding
                if in_local_rhs and local_pending[value] then
                    binding = current.parent and find(current.parent, value) or nil
                else
                    binding = find(current, value)
                end
                if binding then replacements[token.start] = binding.output end
            end
        elseif value == "local" then
            declaring = true
            is_local_decl = true
            -- The self-reference guard is per-statement; names from an earlier local are ordinary locals in this statement's RHS and must be renamed. Stale entries here would leave them unrenamed.
            local_pending = {}
        elseif declaring and value == "function" then
            declaring = false
            local_function = true
        elseif value == "for" then
            for_declaration = true
            is_local_decl = false
        elseif value == "function" then
            push("function")
            function_header = true
        elseif value == "(" and function_header then
            parameters = true
            param_type = false
            type_depth = 0
            function_header = false
        elseif parameters and param_type then
            -- Inside a parameter's type annotation: track nesting of <>, {}, ()
            -- so we know when the type (and possibly the parameter list) ends.
            if value == "(" or value == "{" or value == "<" then
                type_depth = type_depth + 1
            elseif value == "}" or value == ">" then
                type_depth = math.max(0, type_depth - 1)
            elseif value == ")" then
                if type_depth > 0 then type_depth = type_depth - 1
                else param_type = false; parameters = false end
            elseif value == "," and type_depth == 0 then
                param_type = false
            end
        elseif value == ":" and parameters then
            param_type = true
            type_depth = 0
        elseif value == ")" and parameters then
            parameters = false
        elseif value == "then" or value == "do" or value == "repeat" then
            push(value)
        elseif value == "else" or value == "elseif" then
            pop()
            push(value)
        elseif value == "end" then
            pop()
        elseif value == "until" then
            -- repeat...until: don't pop here. The condition still sees the repeat scope; the deferred-pop logic above closes it when the condition ends.
            repeat_condition = true
            repeat_depth = 0
        elseif declaring and value == "=" then
            declaring = false
        elseif declaring and value ~= "," then
            declaring = false
        end
        if token.kind == "symbol" and value == "{" then braces = braces + 1
        elseif token.kind == "symbol" and value == "}" then braces = math.max(0, braces - 1) end
    end

    -- Single forward pass into a buffer: O(n) instead of rebuilding the whole
    -- source string on every renamed identifier.
    local out, cursor = {}, 1
    for index = 1, #tokens do
        local token = tokens[index]
        local value = replacements[token.start] or (declarations[token.start] and declarations[token.start].output)
        if value then
            out[#out + 1] = source:sub(cursor, token.start - 1)
            out[#out + 1] = value
            cursor = token.finish + 1
        end
    end
    out[#out + 1] = source:sub(cursor)
    return table.concat(out)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
