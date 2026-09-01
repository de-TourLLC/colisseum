-- Luau types are compile-time metadata. Colisseum's native VMs execute Lua
-- values, so erase supported type syntax before the source reaches their Lua AST.
-- The scanner works on tokens and preserves newlines, strings, and comments.
local Lexer = require("src.core.lexer")

local Types = {}

local statement_starters = {
    ["export"] = true, ["type"] = true, ["local"] = true, ["function"] = true,
    ["return"] = true, ["if"] = true, ["for"] = true, ["while"] = true,
    ["repeat"] = true, ["do"] = true, ["break"] = true, ["continue"] = true,
    ["elseif"] = true, ["else"] = true, ["end"] = true, ["until"] = true,
}

local opening = { ["("] = true, ["{"] = true, ["["] = true, ["<"] = true }
local closing = { [")"] = true, ["}"] = true, ["]"] = true, [">"] = true }

local function significant(source)
    local tokens = {}
    for _, token in ipairs(Lexer.scan(source)) do
        if token.kind ~= "comment" then tokens[#tokens + 1] = token end
    end
    return tokens
end

local function has_newline(source, left, right)
    return source:sub(left.finish + 1, right.start - 1):find("[\r\n]") ~= nil
end

function Types.erase(source)
    if type(source) ~= "string" then error("luau-type-erase: source must be a string") end
    local tokens = significant(source)
    if #tokens == 0 then return source end

    local removed = {}
    local function remove(first, last)
        if first > last then return end
        for position = first, last do
            if source:sub(position, position):match("[^\r\n]") then removed[position] = true end
        end
    end

    -- Return the last token of a type expression. Delimiters at the outermost
    -- level belong to the surrounding Lua expression and are retained.
    local function type_end(start, stop, stop_on_newline)
        local depth = 0
        local index = start
        while index <= #tokens do
            local token = tokens[index]
            if depth == 0 and (stop[token.value] or
                (stop_on_newline and index > start and has_newline(source, tokens[index - 1], token))) then
                return index - 1
            end
            if opening[token.value] then
                depth = depth + 1
            elseif closing[token.value] and depth > 0 then
                depth = depth - 1
            end
            index = index + 1
        end
        return #tokens
    end

    -- `export type T = ...` and `type T = ...` have no runtime equivalent.
    -- A new statement on a later line ends the declaration; nested type tables,
    -- function signatures, and generics are tracked by `depth` above.
    local index = 1
    while index <= #tokens do
        local token = tokens[index]
        local type_index = token.value == "export" and index + 1 or index
        local name = tokens[type_index + 1]
        local follows_name = tokens[type_index + 2]
        -- `type` is also Lua's standard runtime function. It is a declaration
        -- only when followed by an alias name and either `=` or generic `<...>`;
        -- notably, `type(value)` must remain untouched.
        local alias = tokens[type_index] and tokens[type_index].value == "type" and
            name and name.kind == "identifier" and follows_name and
            (follows_name.value == "=" or follows_name.value == "<")
        if alias then
            local finish = type_end(type_index + 1, { [";"] = true }, true)
            remove(token.start, tokens[finish].finish)
            index = finish + 1
        else
            index = index + 1
        end
    end

    -- Function parameter annotations and return annotations.
    index = 1
    while index <= #tokens do
        if tokens[index].value == "function" then
            local open = index + 1
            while open <= #tokens and tokens[open].value ~= "(" do open = open + 1 end
            if open <= #tokens then
                local depth, close = 1, open + 1
                while close <= #tokens and depth > 0 do
                    if tokens[close].value == "(" then depth = depth + 1
                    elseif tokens[close].value == ")" then depth = depth - 1 end
                    close = close + 1
                end
                local parameter = open + 1
                while parameter < close - 1 do
                    if tokens[parameter].value == ":" then
                        local finish = type_end(parameter + 1, { [","] = true, [")"] = true }, false)
                        remove(tokens[parameter].start, tokens[finish].finish)
                        parameter = finish
                    end
                    parameter = parameter + 1
                end
                local annotation = tokens[close]
                if annotation and annotation.value == ":" then
                    local finish = type_end(close + 1, statement_starters, true)
                    remove(annotation.start, tokens[finish].finish)
                end
                index = close
            end
        end
        index = index + 1
    end

    -- Local variable annotations (`local value: number = 1`).
    index = 1
    while index <= #tokens do
        if tokens[index].value == "local" and tokens[index + 1] and tokens[index + 1].value ~= "function" then
            local cursor = index + 1
            while cursor <= #tokens and tokens[cursor].value ~= "=" and
                not (cursor > index + 1 and has_newline(source, tokens[cursor - 1], tokens[cursor])) do
                if tokens[cursor].value == ":" then
                    local finish = type_end(cursor + 1, { [","] = true, ["="] = true }, false)
                    remove(tokens[cursor].start, tokens[finish].finish)
                    cursor = finish
                end
                cursor = cursor + 1
            end
            index = cursor
        end
        index = index + 1
    end

    -- Type assertions: `(value :: SomeType)` becomes `(value)`.
    for position, token in ipairs(tokens) do
        if token.value == "::" then
            local finish = type_end(position + 1, {
                [")"] = true, ["]"] = true, ["}"] = true, [","] = true,
                [";"] = true, ["["] = true,
            }, true)
            remove(token.start, tokens[finish].finish)
        end
    end

    if not next(removed) then return source end
    local out = {}
    for position = 1, #source do
        out[position] = removed[position] and " " or source:sub(position, position)
    end
    return table.concat(out)
end

return Types
