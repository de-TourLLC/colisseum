local Lexer = require("src.core.lexer")

local Step = {}
Step.name = "field-index"
Step.version = 2
-- Every rewrite turns `a.b` into `a["<b>"]`, which is exactly equivalent field
-- access in Lua, so the result is valid by construction.
Step.emits_valid = true

-- Adapted from Luraph's API indirection: rewrite dotted field access `a.b` into
-- bracket-indexed `a["\098"]` (key spelled as decimal escapes), so pattern-based
-- deobfuscators can no longer grep for field and method names.
--
-- IMPORTANT compatibility rule: the standard libraries and host singletons are
-- left in dot form. Luau compiles `string.char` to a fast import that the Fiu VM
-- (the `--secure` backend) resolves, but `string["char"]` compiles to a runtime
-- GETGLOBAL that Fiu does not expose for the stdlib, which would make the base nil
-- at run time. Restricting the rewrite to user tables / locals keeps the output
-- correct under Lua 5.1, LuaJIT, Luau, Roblox and the Fiu VM alike, while still
-- hiding the names that actually matter (user object methods, local aliases).
local protected_bases = {
    string = true, table = true, math = true, coroutine = true, debug = true,
    os = true, io = true, utf8 = true, bit32 = true, buffer = true, task = true,
    vector = true, _G = true, _ENV = true, game = true, workspace = true,
    script = true, shared = true, plugin = true, Enum = true,
}

local function escape_key(name)
    local parts = {}
    for index = 1, #name do
        parts[index] = string.format("\\%03d", name:byte(index))
    end
    return "[\"" .. table.concat(parts) .. "\"]"
end

function Step.apply(source, options)
    if type(source) ~= "string" then error("field-index: source must be a string") end
    if options ~= nil and type(options) ~= "table" then error("field-index: options must be a table") end

    local tokens = Lexer.scan(source)
    -- Significant tokens only (comments never affect grammar here).
    local sig = {}
    for _, token in ipairs(tokens) do
        if token.kind ~= "comment" then sig[#sig + 1] = token end
    end

    -- One ordered pass: track whether we are inside a `function <name>...(` header
    -- (where a dotted name may not be bracketed) and collect the dots to rewrite.
    local points = {}
    local in_def_header = false
    for i = 1, #sig do
        local token = sig[i]
        if token.kind == "identifier" and token.value == "function" then
            local next_token = sig[i + 1]
            in_def_header = next_token ~= nil and next_token.kind == "identifier"
        elseif in_def_header and token.kind == "symbol" and token.value == "(" then
            in_def_header = false
        elseif token.kind == "symbol" and token.value == "." and not in_def_header then
            local name = sig[i + 1]
            local base = sig[i - 1]
            -- Only rewrite when the base is a plain identifier that is not a
            -- protected library/singleton. A base like `)`/`]`/`}` (e.g.
            -- `(expr).field`) is a user value and is always safe to rewrite.
            local base_ok = base == nil or base.kind ~= "identifier" or not protected_bases[base.value]
            if name ~= nil and name.kind == "identifier" and base_ok then
                points[#points + 1] = { dot = token, name = name }
            end
        end
    end

    local out, cursor = {}, 1
    for _, point in ipairs(points) do
        out[#out + 1] = source:sub(cursor, point.dot.start - 1)
        out[#out + 1] = escape_key(point.name.value)
        cursor = point.name.finish + 1
    end
    out[#out + 1] = source:sub(cursor)
    return table.concat(out)
end

setmetatable(Step, { __call = function(self, source, options) return self.apply(source, options) end })
return Step
