--[[
    Lowers Luau-only sugar to plain Lua before the pipeline runs:
      `a {x} b`            -> ("a"..tostring(x).." b")
      if c then a else b   -> (function() if c then return a else return b end end)()
    Holes and branches are copied verbatim, so the renamer and the validator see their
    identifiers as ordinary tokens; literal parts become "\ddd" string literals. The
    parser understands both forms directly, so this is only for the full pipeline.
]]

local Lexer = require("src.core.lexer")

local M = {}

-- Decode a literal part (interp + standard escapes) to raw bytes.
local function decode_literal(s)
    local out, i, n = {}, 1, #s
    local simple = { a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v",
        ["\\"] = "\\", ["`"] = "`", ["{"] = "{", ["}"] = "}", ['"'] = '"', ["'"] = "'" }
    while i <= n do
        local c = s:sub(i, i)
        if c ~= "\\" then out[#out + 1] = c; i = i + 1
        else
            local e = s:sub(i + 1, i + 1)
            if simple[e] then out[#out + 1] = simple[e]; i = i + 2
            elseif e == "x" then out[#out + 1] = string.char(tonumber(s:sub(i + 2, i + 3), 16) or 0); i = i + 4
            elseif e:match("%d") then local d = s:sub(i + 1):match("^%d%d?%d?"); out[#out + 1] = string.char(tonumber(d)); i = i + 1 + #d
            else out[#out + 1] = e; i = i + 2 end
        end
    end
    return table.concat(out)
end

local function quote(bytes)
    return '"' .. bytes:gsub(".", function(c) return string.format("\\%03d", c:byte()) end) .. '"'
end

-- Desugar one interp token's raw value (with backticks) into plain-Lua text.
local function lower_token(raw)
    local body = raw:sub(2, -2)
    local pieces, lit, i, n = {}, {}, 1, #body
    local function flush() if #lit > 0 then pieces[#pieces + 1] = { str = table.concat(lit) }; lit = {} end end
    while i <= n do
        local c = body:sub(i, i)
        if c == "\\" then lit[#lit + 1] = body:sub(i, i + 1); i = i + 2
        elseif c == "{" then
            flush()
            local depth, j = 1, i + 1
            while j <= n and depth > 0 do
                local cj = body:sub(j, j)
                if cj == "\\" then j = j + 2
                elseif cj == "{" then depth = depth + 1; j = j + 1
                elseif cj == "}" then depth = depth - 1; j = j + 1
                elseif cj == "\"" or cj == "'" then
                    local q = cj; j = j + 1
                    while j <= n do local c2 = body:sub(j, j); if c2 == "\\" then j = j + 2 elseif c2 == q then j = j + 1; break else j = j + 1 end end
                else j = j + 1 end
            end
            pieces[#pieces + 1] = { expr = body:sub(i + 1, j - 2) }
            i = j
        else lit[#lit + 1] = c; i = i + 1 end
    end
    flush()
    local out = {}
    for _, p in ipairs(pieces) do
        if p.str then out[#out + 1] = quote(decode_literal(p.str))
        else out[#out + 1] = "tostring(" .. p.expr .. ")" end
    end
    if #out == 0 then return '""' end
    return "(" .. table.concat(out, "..") .. ")"
end

-- leftmost if-else expression node in an AST (smallest source start)
local function find_ifexpr(node, best)
    if type(node) ~= "table" then return best end
    if node.kind == "ifexpr" and node.start then
        if not best or node.start < best.start then best = node end
    end
    for k, v in pairs(node) do
        if type(v) == "table" and k ~= "start" and k ~= "finish" then
            if v.kind then best = find_ifexpr(v, best)
            else for _, e in ipairs(v) do best = find_ifexpr(e, best) end end
        end
    end
    return best
end

--[[ if c then a else b  ->  an IIFE the validator, renamer and VM all understand.
     one outermost node per pass, re-parsing each time, so nested ones converge.
     parses a type-erased copy when the source carries types the parser can't read. ]]
function M.lower_ifexpr(source)
    if type(source) ~= "string" or not source:find("if", 1, true) then return source end
    local Parser = require("src.core.parser")
    if not pcall(Parser.parse, source) then
        local erased = require("src.core.luau-type-erase").erase(source)
        if pcall(Parser.parse, erased) then source = erased else return source end
    end
    for _ = 1, 10000 do
        local ok, ast = pcall(Parser.parse, source)
        if not ok then return source end
        local node = find_ifexpr(ast, nil)
        if not node then return source end
        local parts = {}
        for _, cl in ipairs(node.clauses) do
            parts[#parts + 1] = (#parts == 0 and "if " or " elseif ")
            parts[#parts + 1] = source:sub(cl.cond.start, cl.cond.finish)
            parts[#parts + 1] = " then return "
            parts[#parts + 1] = source:sub(cl.value.start, cl.value.finish)
        end
        parts[#parts + 1] = " else return "
        parts[#parts + 1] = source:sub(node.fallback.start, node.fallback.finish)
        parts[#parts + 1] = " end"
        local iife = "(function() " .. table.concat(parts) .. " end)()"
        source = source:sub(1, node.start - 1) .. iife .. source:sub(node.finish + 1)
    end
    return source
end

-- Lower all Luau-only expression sugar (interpolation then if-else expressions).
function M.lower_all(source)
    return M.lower_ifexpr(M.lower(source))
end

-- Replace every interpolated-string span in `source` with its lowered text.
function M.lower(source)
    if type(source) ~= "string" or not source:find("`", 1, true) then return source end
    local out, cursor = {}, 1
    for _, t in ipairs(Lexer.scan(source)) do
        if t.kind == "interp" then
            out[#out + 1] = source:sub(cursor, t.start - 1)
            out[#out + 1] = lower_token(t.value)
            cursor = t.finish + 1
        end
    end
    out[#out + 1] = source:sub(cursor)
    return table.concat(out)
end

return M
