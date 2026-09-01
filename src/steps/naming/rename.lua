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

    for index, token in ipairs(tokens) do
        local value = token.value
        local before = previous(index)
        local after = next_token(index)
        if token.kind == "identifier" and not reserved[value] then
            local field = before and (before.value == "." or before.value == ":")
            local table_key = after and after.value == "=" and braces > 0
            if parameters then
                -- Declare real parameter names, but never the identifiers inside a
                -- Luau type annotation (`p: SomeType`). Binding a type name would
                -- rename every later use of it -- including globals such as
                -- `string` in `string.reverse`.
                if not param_type then
                    local binding = declaration(current, value, generator, declarations)
                    declarations[token.start] = binding
                end
            elseif local_function then
                -- `local function f` binds f in the CURRENT scope (visible after the
                -- definition), then opens a new scope for its parameters and body so
                -- the closing `end` pops that inner scope, not the enclosing one.
                local binding = declaration(current, value, generator, declarations)
                declarations[token.start] = binding
                push("function")
                local_function = false
                function_header = true
            elseif declaring or for_declaration then
                if not field then
                    local binding = declaration(current, value, generator, declarations)
                    declarations[token.start] = binding
                    declaring = after and after.value == ","
                    for_declaration = false
                end
            elseif not field and not table_key then
                local binding = find(current, value)
                if binding then replacements[token.start] = binding.output end
            end
        elseif value == "local" then
            declaring = true
        elseif declaring and value == "function" then
            declaring = false
            local_function = true
        elseif value == "for" then
            for_declaration = true
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
        elseif value == "end" or value == "until" then
            pop()
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
