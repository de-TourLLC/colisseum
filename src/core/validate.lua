local Lexer = require("src.core.lexer")

local Validate = {}

-- Lightweight structural validation over a scanned token stream:
--   1. Balanced (), [], {} brackets (original behavior).
--   2. Balanced block structure: `if`/`while`/`for`/`function`/`repeat`/`do`
--      open a block and must be closed by a matching `end`/`until`. `elseif` and
--      `else` only transition between branches of an open `if`; the single
--      trailing `end` closes all of its branches. This rejects an `if` without a
--      `then`, a stray `end`, a mismatched `until`, or any other unbalanced block
--      that a broken transformation step could otherwise ship past a bracket-only
--      check.
-- This is intentionally not a full parser (no expression proof), but it is safe
-- for both the Lua and Luau token sets the obfuscator emits.
function Validate.syntax(source)
    local stack = {}
    local pairs = { [")"] = "(", ["]"] = "[", ["}"] = "{" }
    for _, token in ipairs(Lexer.scan(source)) do
        if token.kind == "symbol" then
            if token.value == "(" or token.value == "[" or token.value == "{" then
                stack[#stack + 1] = token
            elseif pairs[token.value] then
                local opening = stack[#stack]
                if not opening or opening.value ~= pairs[token.value] then
                    return false, "unexpected " .. token.value, token.start
                end
                stack[#stack] = nil
            end
        elseif token.kind == "keyword" then
            local value = token.value
            if value == "if" or value == "while" or value == "for" then
                stack[#stack + 1] = value
            elseif value == "function" or value == "repeat" then
                stack[#stack + 1] = value
            elseif value == "do" then
                -- `while`/`for` require a `do` to open their body; a plain block
                -- `do` opens one directly.
                local opener = stack[#stack]
                if opener == "while" or opener == "for" then
                    stack[#stack] = "do"
                else
                    stack[#stack + 1] = "do"
                end
            elseif value == "then" then
                -- Transition an `if` (or an `elseif` (re)opened by `elseif`) into
                -- its branch body.
                local opener = stack[#stack]
                if opener == "if" or opener == "elseif" then
                    stack[#stack] = "then"
                else
                    return false, "'then' outside an if-statement", token.start
                end
            elseif value == "elseif" or value == "else" then
                local opener = stack[#stack]
                if opener == "then" or opener == "elseif" then
                    stack[#stack] = value == "elseif" and "elseif" or "else"
                else
                    return false, "unexpected " .. value, token.start
                end
            elseif value == "until" then
                local opener = stack[#stack]
                if opener ~= "repeat" then
                    return false, "unexpected 'until'", token.start
                end
                stack[#stack] = nil
            elseif value == "end" then
                local opener = stack[#stack]
                if opener == "then" or opener == "else" or opener == "do" or
                    opener == "function" or opener == "repeat" then
                    stack[#stack] = nil
                elseif not opener then
                    return false, "unexpected 'end'", token.start
                else
                    return false, "mismatched 'end' after " .. tostring(opener), token.start
                end
            end
        end
    end
    for index = #stack, 1, -1 do
        local entry = stack[index]
        if entry ~= "(" and entry ~= "[" and entry ~= "{" then
            return false, "unclosed block " .. entry, 0
        end
    end
    if #stack > 0 then
        return false, "unclosed " .. stack[#stack].value, stack[#stack].start
    end
    return true
end

return Validate