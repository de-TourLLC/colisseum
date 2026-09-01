-- Register VM compiler: Lua AST (from src.core.parser) -> a proto tree for the
-- register interpreter (src.core.reg-runtime). Single-pass codegen with a small
-- register allocator, constant interning, jump patching, boxed upvalues, and
-- Lua-correct multi-value alignment for calls/returns/varargs/table constructors.
-- No loadstring.

local Parser = require("src.core.parser")
local LuauTypes = require("src.core.luau-type-erase")
local RB = require("src.core.reg-bytecode")
local OP = RB.OP

local RegCompiler = {}

-- ---- capture analysis -------------------------------------------------------
-- A function's local/param is "captured" if any nested function references its
-- name. Over-approximate (ignores shadowing inside nested functions): boxing a
-- non-captured local is still correct, just marginally slower.

local function has_vararg(params)
    for _, p in ipairs(params) do if p == "..." then return true end end
    return false
end

local function real_params(params)
    local out = {}
    for _, p in ipairs(params) do if p ~= "..." then out[#out + 1] = p end end
    return out
end

local function walk(node, on_node)
    if type(node) ~= "table" then return end
    on_node(node)
    for k, v in pairs(node) do
        if type(v) == "table" and k ~= "start" and k ~= "finish" then
            if v.kind then walk(v, on_node)
            else for _, e in ipairs(v) do walk(e, on_node) end end
        end
    end
end

-- Names bound by params + local declarations directly in a function body (not
-- descending into nested functions).
local function own_bindings(params, body)
    local names = {}
    for _, p in ipairs(params) do names[p] = true end
    local function scan(list)
        for _, stmt in ipairs(list) do
            local k = stmt.kind
            if k == "local" then for _, n in ipairs(stmt.names) do names[n] = true end
            elseif k == "function" and stmt.local_function then names[stmt.name] = true
            elseif k == "for" then names[stmt.name] = true
            elseif k == "forin" then for _, n in ipairs(stmt.names) do names[n] = true end
            end
            -- descend into non-function control bodies to find inner locals too
            if k == "if" then
                for _, br in ipairs(stmt.branches) do scan(br.body) end
                if stmt.fallback then scan(stmt.fallback) end
            elseif k == "while" or k == "for" or k == "forin" or k == "do" then scan(stmt.body)
            elseif k == "repeat" then scan(stmt.body) end
        end
    end
    scan(body)
    return names
end

-- All identifier names referenced anywhere inside nested functions of this body.
local function idents_in_nested_functions(params, body)
    local seen = {}
    for _, stmt in ipairs(body) do
        walk(stmt, function(n)
            if n.kind == "function" then
                walk(n, function(m) if m.kind == "identifier" then seen[m.value] = true end end)
            end
        end)
    end
    return seen
end

local function captured_set(params, body)
    local bound = own_bindings(params, body)
    local used = idents_in_nested_functions(params, body)
    local cap = {}
    for name in pairs(bound) do if used[name] then cap[name] = true end end
    return cap
end

-- ---- function compilation ---------------------------------------------------

local function new_fstate(parent)
    return {
        parent = parent,
        proto = { code = {}, constants = {}, protos = {}, upvals = {}, numparams = 0, is_vararg = false },
        kcache = {},
        actives = {},   -- stack of { name, reg, captured }
        nactive = 0,
        freereg = 0,
        maxstack = 0,
        captured = {},  -- name -> true (from pre-pass)
        loops = {},     -- stack of { breaks = {jmp indices} }
    }
end

local function compile_function(params, body, is_vararg, parent)
    local vararg = is_vararg or has_vararg(params)
    params = real_params(params)
    local fs = new_fstate(parent)
    local proto = fs.proto
    proto.numparams = #params
    proto.is_vararg = vararg
    fs.captured = captured_set(params, body)

    local code = proto.code

    local function emit(op, a, b, c) code[#code + 1] = { op, a or 0, b or 0, c or 0 }; return #code end
    local function here() return #code end
    local function reserve(n)
        if fs.freereg + n > fs.maxstack then fs.maxstack = fs.freereg + n end
    end
    local function alloc()
        local r = fs.freereg; fs.freereg = fs.freereg + 1
        if fs.freereg > fs.maxstack then fs.maxstack = fs.freereg end
        return r
    end
    local function setfree(n) fs.freereg = n end

    local function kidx(value)
        local cache = fs.kcache
        local key = type(value) .. "\0" .. tostring(value)
        if cache[key] then return cache[key] end
        proto.constants[#proto.constants + 1] = value
        local i = #proto.constants
        cache[key] = i
        return i
    end

    -- scope management -------------------------------------------------------
    local function declare_local(name)
        local reg = fs.nactive
        fs.nactive = fs.nactive + 1
        if fs.nactive > fs.maxstack then fs.maxstack = fs.nactive end
        if fs.freereg < fs.nactive then fs.freereg = fs.nactive end
        local cap = fs.captured[name] == true
        fs.actives[#fs.actives + 1] = { name = name, reg = reg, captured = cap }
        if cap then emit(OP.NEWCELL, reg, reg) end -- box: R[reg] = { R[reg] } (initial garbage; callers set before/after as needed)
        return reg, cap
    end
    local function scope_mark() return #fs.actives, fs.nactive, fs.freereg end
    local function scope_restore(mark_actives, mark_nactive, mark_freereg)
        for i = #fs.actives, mark_actives + 1, -1 do fs.actives[i] = nil end
        fs.nactive = mark_nactive
        fs.freereg = mark_nactive
    end

    -- name resolution --------------------------------------------------------
    local function find_local(name)
        for i = #fs.actives, 1, -1 do
            if fs.actives[i].name == name then return fs.actives[i] end
        end
        return nil
    end
    -- Resolve `name` as an upvalue of fs (recursively through parents). Returns the
    -- upvalue index in fs.proto.upvals or nil.
    local function resolve_upval(state, name)
        if not state.parent then return nil end
        -- already an upvalue?
        for i, d in ipairs(state.proto.upvals) do
            if d.name == name then return i end
        end
        -- parent local?
        local plocal
        for i = #state.parent.actives, 1, -1 do
            if state.parent.actives[i].name == name then plocal = state.parent.actives[i]; break end
        end
        if plocal then
            state.proto.upvals[#state.proto.upvals + 1] = { name = name, kind = "local", index = plocal.reg }
            return #state.proto.upvals
        end
        -- parent upvalue?
        local pu = resolve_upval(state.parent, name)
        if pu then
            state.proto.upvals[#state.proto.upvals + 1] = { name = name, kind = "upval", index = pu }
            return #state.proto.upvals
        end
        return nil
    end

    -- forward decls (all closures over this function's state; never globals)
    local expr_to, expr_any, expr_rk, compile_block, compile_stmt, expr_multi, compile_call
    local compile_child_function, compile_table, compile_args
    local compile_if, compile_while, compile_repeat, compile_for, compile_forin

    -- Load a variable (local/upval/global) into register `reg`.
    local function load_var(name, reg)
        local loc = find_local(name)
        if loc then
            if loc.captured then emit(OP.GETCELL, reg, loc.reg)
            elseif loc.reg ~= reg then emit(OP.MOVE, reg, loc.reg) end
            return
        end
        local uv = resolve_upval(fs, name)
        if uv then emit(OP.GETUPVAL, reg, uv); return end
        emit(OP.GETGLOBAL, reg, kidx(name))
    end
    -- Store register `reg` into variable `name`.
    local function store_var(name, reg)
        local loc = find_local(name)
        if loc then
            if loc.captured then emit(OP.SETCELL, reg, loc.reg)
            elseif loc.reg ~= reg then emit(OP.MOVE, loc.reg, reg) end
            return
        end
        local uv = resolve_upval(fs, name)
        if uv then emit(OP.SETUPVAL, reg, uv); return end
        emit(OP.SETGLOBAL, reg, kidx(name))
    end

    local BINOP = {
        ["+"] = OP.ADD, ["-"] = OP.SUB, ["*"] = OP.MUL, ["/"] = OP.DIV, ["%"] = OP.MOD,
        ["^"] = OP.POW, ["//"] = OP.IDIV, [".."] = OP.CONCAT,
        ["=="] = OP.EQ, ["~="] = OP.NE, ["<"] = OP.LT, ["<="] = OP.LE, [">"] = OP.GT, [">="] = OP.GE,
    }

    -- Is a node a constant we can encode directly as RK?
    local function const_value(node)
        if node.kind == "number" then return tonumber(node.value) end
        if node.kind == "string" then
            -- decode the source string spelling like the tree-walker does
            local Runtime = require("src.core.runtime")
            return Runtime.decode_string and nil -- fallback below
        end
        return nil
    end

    -- Decode a string literal token (source spelling) to its value. Handles long
    -- strings and all Lua escapes including decimal (\ddd) and hex (\xHH), matching
    -- reference Lua -- field-index rewrites keys as \ddd escapes, so this must be
    -- exact.
    local ESC = { a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v", ["\\"] = "\\", ['"'] = '"', ["'"] = "'", ["\n"] = "\n" }
    local function decode_string_literal(src)
        if src:sub(1, 1) == "[" then
            local eq = src:match("^%[(=*)%[")
            local close = "]" .. eq .. "]"
            return src:sub(3 + #eq, #src - #close)
        end
        local body = src:sub(2, -2)
        local out, i, n = {}, 1, #body
        while i <= n do
            local c = body:sub(i, i)
            if c ~= "\\" then out[#out + 1] = c; i = i + 1
            else
                local e = body:sub(i + 1, i + 1)
                if ESC[e] then out[#out + 1] = ESC[e]; i = i + 2
                elseif e == "x" then
                    local hex = body:sub(i + 2):match("^%x%x")
                    out[#out + 1] = string.char(tonumber(hex, 16)); i = i + 4
                elseif e:match("%d") then
                    local dec = body:sub(i + 1):match("^%d%d?%d?")
                    out[#out + 1] = string.char(tonumber(dec)); i = i + 1 + #dec
                elseif e == "z" then
                    i = i + 2; while i <= n and body:sub(i, i):match("%s") do i = i + 1 end
                else out[#out + 1] = e; i = i + 2 end
            end
        end
        return table.concat(out)
    end

    -- expr_rk: returns an RK operand (constant index encoded, or a register).
    -- may allocate a temp register (caller manages freereg).
    expr_rk = function(node)
        if node.kind == "number" then return RB.rk_const(kidx(tonumber(node.value))) end
        if node.kind == "string" then return RB.rk_const(kidx(decode_string_literal(node.value))) end
        local r = alloc(); expr_to(node, r); return r
    end

    -- expr_to: emit code so R[reg] holds node's (single) value.
    expr_to = function(node, reg)
        local k = node.kind
        if k == "number" then emit(OP.LOADK, reg, kidx(tonumber(node.value)))
        elseif k == "string" then emit(OP.LOADK, reg, kidx(decode_string_literal(node.value)))
        elseif k == "literal" then
            if node.value == "nil" then emit(OP.LOADNIL, reg)
            elseif node.value == "true" then emit(OP.LOADBOOL, reg, 1)
            else emit(OP.LOADBOOL, reg, 0) end
        elseif k == "identifier" then load_var(node.value, reg)
        elseif k == "vararg" then emit(OP.VARARG, reg, 2) -- one value
        elseif k == "group" then expr_to(node.value, reg)
        elseif k == "unary" then
            local save = fs.freereg
            local b = expr_rk(node.value)
            if node.operator == "not" then emit(OP.NOT, reg, b)
            elseif node.operator == "-" then emit(OP.NEG, reg, b)
            elseif node.operator == "#" then emit(OP.LEN, reg, b) end
            fs.freereg = save
        elseif k == "binary" then
            local op = node.operator
            if op == "and" or op == "or" then
                -- short circuit: reg = left; if (op=="and" and left falsy) or (op=="or" and left truthy) skip right
                expr_to(node.left, reg)
                local jump_when = (op == "or") -- or: jump (skip right) when left truthy
                emit(OP.TEST, reg, jump_when and 1 or 0)
                local j = emit(OP.JMP, 0)
                expr_to(node.right, reg)
                code[j][2] = here() - j
            else
                local save = fs.freereg
                local b = expr_rk(node.left)
                local c = expr_rk(node.right)
                emit(BINOP[op], reg, b, c)
                fs.freereg = save
            end
        elseif k == "index" then
            local save = fs.freereg
            local t = expr_any(node.object)
            local key = expr_rk(node.key)
            emit(OP.GETTABLE, reg, t, key)
            fs.freereg = save
        elseif k == "member" then
            local save = fs.freereg
            local t = expr_any(node.object)
            emit(OP.GETTABLE, reg, t, RB.rk_const(kidx(node.name)))
            fs.freereg = save
        elseif k == "call" then
            local save = fs.freereg
            local base = compile_call(node, 2) -- want 1 result at base
            emit(OP.MOVE, reg, base)
            fs.freereg = save
        elseif k == "function" then
            local proto_index = compile_child_function(node)
            emit(OP.CLOSURE, reg, proto_index)
        elseif k == "table" then
            compile_table(node, reg)
        else
            error("reg-compiler: cannot compile expression kind '" .. tostring(k) .. "'")
        end
    end

    expr_any = function(node)
        if node.kind == "identifier" then
            local loc = find_local(node.value)
            if loc and not loc.captured then return loc.reg end
        end
        local r = alloc(); expr_to(node, r); return r
    end

    -- compile a nested function node -> index in proto.protos
    compile_child_function = function(node)
        local child = compile_function(node.parameters, node.body, has_vararg(node.parameters), fs)
        proto.protos[#proto.protos + 1] = child
        return #proto.protos
    end

    -- table constructor into reg
    compile_table = function(node, reg)
        emit(OP.NEWTABLE, reg)
        local arrayidx = 0
        local values = node.values
        local save = fs.freereg
        if fs.freereg <= reg then fs.freereg = reg + 1 end
        for i, field in ipairs(values) do
            if field.kind == "field" then
                local vsave = fs.freereg
                local vr = expr_any(field.value)
                emit(OP.SETTABLE, reg, RB.rk_const(kidx(field.key)), vr)
                fs.freereg = vsave
            elseif field.kind == "keyfield" then
                local vsave = fs.freereg
                local kr = expr_rk(field.key)
                local vr = expr_rk(field.value)
                emit(OP.SETTABLE, reg, kr, vr)
                fs.freereg = vsave
            else
                -- array item
                local last = (i == #values)
                if last and (field.kind == "call" or field.kind == "vararg") then
                    -- expand multi-values into consecutive integer keys
                    local vsave = fs.freereg
                    local base = fs.freereg
                    expr_multi(field, base, -1) -- all results at base, sets top
                    emit(OP.SETLIST, reg, base, arrayidx) -- append all from base using top
                    fs.freereg = vsave
                    arrayidx = -1 -- signal handled
                else
                    arrayidx = arrayidx + 1
                    local vsave = fs.freereg
                    local vr = expr_any(field)
                    emit(OP.SETTABLE, reg, RB.rk_const(kidx(arrayidx)), vr)
                    fs.freereg = vsave
                end
            end
        end
        fs.freereg = save
        if fs.freereg <= reg then fs.freereg = reg + 1 end
    end

    -- compile a call node; places the callee at some base register and emits CALL.
    -- want = number of results wanted + 1 (Lua CALL C convention); want==0 -> all.
    -- returns the base register where results begin.
    compile_call = function(node, want)
        local base = fs.freereg
        reserve(1)
        if node.callee.kind == "member" and node.callee.method then
            -- method call a:m(args): SELF puts receiver at base+1, method at base
            local objsave = fs.freereg
            local obj = expr_any(node.callee.object)
            fs.freereg = base
            emit(OP.SELF, base, obj, RB.rk_const(kidx(node.callee.name)))
            fs.freereg = base + 2
            local nargs = compile_args(node.arguments, base + 2)
            emit(OP.CALL, base, (nargs == -1) and 0 or (nargs + 2), want) -- +1 self, +1 C convention
            fs.freereg = base + 1
            return base
        else
            expr_to(node.callee, base)
            fs.freereg = base + 1
            local nargs = compile_args(node.arguments, base + 1)
            emit(OP.CALL, base, (nargs == -1) and 0 or (nargs + 1), want)
            fs.freereg = base + 1
            return base
        end
    end

    -- Evaluate an argument list into consecutive registers starting at `start`.
    -- The final call/vararg argument expands to all its values (top-open).
    -- Returns the fixed count, or -1 when the last arg is multi-value (top-open).
    compile_args = function(args, start)
        fs.freereg = start
        local n = #args
        if n == 0 then return 0 end
        for i = 1, n - 1 do
            local r = alloc()
            expr_to(args[i], r)
        end
        local last = args[n]
        if last.kind == "call" or last.kind == "vararg" then
            local base = alloc()
            expr_multi(last, base, -1)
            return -1 -- open (top set)
        else
            local r = alloc()
            expr_to(last, r)
            return n
        end
    end

    -- expr_multi: place ALL values of a multi-value expr (call/vararg) starting at
    -- `base`. want==-1 => all (sets top). want>=0 => exactly `want` values.
    expr_multi = function(node, base, want)
        if node.kind == "call" then
            local savedfree = fs.freereg
            fs.freereg = base
            local c = (want == -1) and 0 or (want + 1)
            -- inline compile_call but forcing base
            if node.callee.kind == "member" and node.callee.method then
                local obj = expr_any(node.callee.object)
                fs.freereg = base
                emit(OP.SELF, base, obj, RB.rk_const(kidx(node.callee.name)))
                fs.freereg = base + 2
                local nargs = compile_args(node.arguments, base + 2)
                emit(OP.CALL, base, (nargs == -1) and 0 or (nargs + 2), c)
            else
                fs.freereg = base
                expr_to(node.callee, base)
                fs.freereg = base + 1
                local nargs = compile_args(node.arguments, base + 1)
                emit(OP.CALL, base, (nargs == -1) and 0 or (nargs + 1), c)
            end
            if want ~= -1 then fs.freereg = base + want end
        elseif node.kind == "vararg" then
            if want == -1 then emit(OP.VARARG, base, 0)
            else emit(OP.VARARG, base, want + 1); fs.freereg = base + want end
        else
            -- not actually multi: just one value
            expr_to(node, base)
            if want ~= -1 then fs.freereg = base + (want > 0 and want or 0) end
        end
    end

    -- ---- statements --------------------------------------------------------
    compile_block = function(list)
        local m1, m2, m3 = scope_mark()
        for _, stmt in ipairs(list) do compile_stmt(stmt) end
        scope_restore(m1, m2, m3)
    end

    compile_stmt = function(stmt)
        local k = stmt.kind
        fs.freereg = fs.nactive
        if k == "local" then
            local nnames = #stmt.names
            local nvals = #stmt.values
            -- evaluate values into temps above nactive, then bind to new local slots
            local base = fs.nactive
            fs.freereg = base
            if nvals == 0 then
                for i = 1, nnames do local r = alloc(); emit(OP.LOADNIL, r) end
            else
                for i = 1, nvals - 1 do local r = alloc(); expr_to(stmt.values[i], r) end
                local last = stmt.values[nvals]
                if (last.kind == "call" or last.kind == "vararg") and nnames >= nvals then
                    local r = alloc()
                    expr_multi(last, r, nnames - nvals + 1)
                    for _ = nvals + 1, nnames do alloc() end
                else
                    local r = alloc(); expr_to(last, r)
                    for _ = nvals + 1, nnames do local rr = alloc(); emit(OP.LOADNIL, rr) end
                end
            end
            -- now registers base..base+nnames-1 hold the values; declare them as locals
            for i = 1, nnames do
                local name = stmt.names[i]
                local reg = base + i - 1
                fs.nactive = reg + 1
                local cap = fs.captured[name] == true
                fs.actives[#fs.actives + 1] = { name = name, reg = reg, captured = cap }
                if cap then emit(OP.NEWCELL, reg, reg) end
            end
            if fs.freereg < fs.nactive then fs.freereg = fs.nactive end
        elseif k == "assign" then
            local target = stmt.target
            if target.kind == "identifier" then
                local loc = find_local(target.value)
                if loc and not loc.captured then expr_to(stmt.value, loc.reg)
                else local r = expr_any(stmt.value); store_var(target.value, r); fs.freereg = fs.nactive end
            elseif target.kind == "member" then
                local t = expr_any(target.object)
                local v = expr_rk(stmt.value)
                emit(OP.SETTABLE, t, RB.rk_const(kidx(target.name)), v)
                fs.freereg = fs.nactive
            elseif target.kind == "index" then
                local t = expr_any(target.object)
                local key = expr_rk(target.key)
                local v = expr_rk(stmt.value)
                emit(OP.SETTABLE, t, key, v)
                fs.freereg = fs.nactive
            end
        elseif k == "massign" then
            local targets, values = stmt.targets, stmt.values
            local base = fs.freereg
            -- evaluate all values into consecutive temps (Lua evaluates RHS first)
            local nt = #targets
            local vbase = fs.freereg
            local nv = #values
            for i = 1, nv - 1 do local r = alloc(); expr_to(values[i], r) end
            local last = values[nv]
            if (last.kind == "call" or last.kind == "vararg") and nt > nv then
                local r = alloc(); expr_multi(last, r, nt - nv + 1)
                for _ = nv + 1, nt do alloc() end
            else
                local r = alloc(); expr_to(last, r)
                for _ = nv + 1, nt do local rr = alloc(); emit(OP.LOADNIL, rr) end
            end
            -- assign temps to targets
            for i = 1, nt do
                local tgt = targets[i]
                local src = vbase + i - 1
                if tgt.kind == "identifier" then store_var(tgt.value, src)
                elseif tgt.kind == "member" then
                    local tsave = fs.freereg
                    local t = expr_any(tgt.object)
                    emit(OP.SETTABLE, t, RB.rk_const(kidx(tgt.name)), src)
                    fs.freereg = tsave
                elseif tgt.kind == "index" then
                    local tsave = fs.freereg
                    local t = expr_any(tgt.object)
                    local key = expr_rk(tgt.key)
                    emit(OP.SETTABLE, t, key, src)
                    fs.freereg = tsave
                end
            end
            fs.freereg = fs.nactive
        elseif k == "expression" then
            local v = stmt.value
            if v.kind == "call" then compile_call(v, 1) -- 0 results wanted (want=1 -> c-1=0)
            else expr_any(v) end
            fs.freereg = fs.nactive
        elseif k == "function" then
            if stmt.local_function then
                local reg = fs.nactive
                fs.nactive = reg + 1
                local cap = fs.captured[stmt.name] == true
                fs.actives[#fs.actives + 1] = { name = stmt.name, reg = reg, captured = cap }
                if cap then emit(OP.NEWCELL, reg, reg) end
                fs.freereg = fs.nactive
                local pidx = compile_child_function({ parameters = stmt.parameters, body = stmt.body, kind = "function" })
                if cap then local t = alloc(); emit(OP.CLOSURE, t, pidx); emit(OP.SETCELL, t, reg); fs.freereg = fs.nactive
                else emit(OP.CLOSURE, reg, pidx) end
            else
                local pidx = compile_child_function({ parameters = stmt.parameters, body = stmt.body, kind = "function" })
                local r = alloc(); emit(OP.CLOSURE, r, pidx)
                store_var(stmt.name, r); fs.freereg = fs.nactive
            end
        elseif k == "return" then
            local vals = stmt.values
            local n = #vals
            if n == 0 then emit(OP.RETURN, 0, 1)
            else
                local base = fs.freereg
                for i = 1, n - 1 do local r = alloc(); expr_to(vals[i], r) end
                local last = vals[n]
                if last.kind == "call" or last.kind == "vararg" then
                    local r = alloc(); expr_multi(last, r, -1)
                    emit(OP.RETURN, base, 0)
                else
                    local r = alloc(); expr_to(last, r)
                    emit(OP.RETURN, base, n + 1)
                end
                fs.freereg = fs.nactive
            end
        elseif k == "break" then
            local loop = fs.loops[#fs.loops]
            if not loop then error("reg-compiler: break outside loop") end
            local j = emit(OP.JMP, 0)
            loop.breaks[#loop.breaks + 1] = j
        elseif k == "do" then
            compile_block(stmt.body)
        elseif k == "if" then
            compile_if(stmt)
        elseif k == "while" then
            compile_while(stmt)
        elseif k == "repeat" then
            compile_repeat(stmt)
        elseif k == "for" then
            compile_for(stmt)
        elseif k == "forin" then
            compile_forin(stmt)
        else
            error("reg-compiler: cannot compile statement kind '" .. tostring(k) .. "'")
        end
    end

    compile_if = function(stmt)
        local end_jumps = {}
        for _, branch in ipairs(stmt.branches) do
            fs.freereg = fs.nactive
            local c = expr_any(branch.condition)
            emit(OP.TEST, c, 0)     -- if cond falsy -> take JMP over this branch
            local skip = emit(OP.JMP, 0)
            fs.freereg = fs.nactive
            compile_block(branch.body)
            end_jumps[#end_jumps + 1] = emit(OP.JMP, 0) -- jump to end after branch body
            code[skip][2] = here() - skip
        end
        if stmt.fallback then
            fs.freereg = fs.nactive
            compile_block(stmt.fallback)
        end
        for _, j in ipairs(end_jumps) do code[j][2] = here() - j end
    end

    compile_while = function(stmt)
        local top = here()
        fs.freereg = fs.nactive
        local c = expr_any(stmt.condition)
        emit(OP.TEST, c, 0)
        local exit = emit(OP.JMP, 0)
        fs.loops[#fs.loops + 1] = { breaks = {} }
        fs.freereg = fs.nactive
        compile_block(stmt.body)
        emit(OP.JMP, top - here() - 1) -- jump back to top
        code[exit][2] = here() - exit
        local loop = fs.loops[#fs.loops]; fs.loops[#fs.loops] = nil
        for _, j in ipairs(loop.breaks) do code[j][2] = here() - j end
    end

    compile_repeat = function(stmt)
        local top = here()
        fs.loops[#fs.loops + 1] = { breaks = {} }
        local m1, m2, m3 = scope_mark()
        fs.freereg = fs.nactive
        for _, s in ipairs(stmt.body) do compile_stmt(s) end
        fs.freereg = fs.nactive
        local c = expr_any(stmt.condition)
        emit(OP.TEST, c, 0)               -- if cond falsy -> loop again
        emit(OP.JMP, top - here() - 1)
        scope_restore(m1, m2, m3)
        local loop = fs.loops[#fs.loops]; fs.loops[#fs.loops] = nil
        for _, j in ipairs(loop.breaks) do code[j][2] = here() - j end
    end

    compile_for = function(stmt)
        local m1, m2, m3 = scope_mark()
        local base = fs.nactive
        fs.freereg = base
        local rinit = alloc(); expr_to(stmt.initial, rinit)
        local rlim = alloc(); expr_to(stmt.limit, rlim)
        local rstep = alloc()
        if stmt.step then expr_to(stmt.step, rstep) else emit(OP.LOADK, rstep, kidx(1)) end
        -- control regs occupy base..base+2; loop var at base+3
        fs.nactive = base + 4
        if fs.maxstack < fs.nactive then fs.maxstack = fs.nactive end
        local prep = emit(OP.FORPREP, base, 0)
        fs.loops[#fs.loops + 1] = { breaks = {} }
        -- declare loop variable at base+3
        local cap = fs.captured[stmt.name] == true
        fs.actives[#fs.actives + 1] = { name = stmt.name, reg = base + 3, captured = cap }
        if cap then emit(OP.NEWCELL, base + 3, base + 3) end
        local body_start = here()
        fs.freereg = fs.nactive
        compile_block(stmt.body)
        code[prep][3] = here() - prep  -- FORPREP jumps to the FORLOOP emitted next
        emit(OP.FORLOOP, base, body_start - here() - 1)
        local loop = fs.loops[#fs.loops]; fs.loops[#fs.loops] = nil
        for _, j in ipairs(loop.breaks) do code[j][2] = here() - j end
        scope_restore(m1, m2, m3)
    end

    compile_forin = function(stmt)
        local m1, m2, m3 = scope_mark()
        local base = fs.nactive
        fs.freereg = base
        -- evaluate the explist into iterator/state/control at base,base+1,base+2
        local exprs = stmt.exprs
        local ne = #exprs
        for i = 1, ne - 1 do local r = alloc(); expr_to(exprs[i], r) end
        local last = exprs[ne]
        if last.kind == "call" or last.kind == "vararg" then
            local r = alloc(); expr_multi(last, r, 3 - (ne - 1))
            for _ = ne + 1, 3 do end
        else
            local r = alloc(); expr_to(last, r)
        end
        while fs.freereg < base + 3 do local r = alloc(); emit(OP.LOADNIL, r) end
        local nnames = #stmt.names
        -- reserve loop-var registers at base+3 .. base+2+nnames
        fs.nactive = base + 3 + nnames
        if fs.maxstack < fs.nactive then fs.maxstack = fs.nactive end
        local jmp_to_call = emit(OP.JMP, 0) -- jump to TFORCALL
        fs.loops[#fs.loops + 1] = { breaks = {} }
        -- declare loop vars
        for i = 1, nnames do
            local name = stmt.names[i]
            local cap = fs.captured[name] == true
            fs.actives[#fs.actives + 1] = { name = name, reg = base + 2 + i, captured = cap }
            if cap then emit(OP.NEWCELL, base + 2 + i, base + 2 + i) end
        end
        local body_start = here()
        fs.freereg = fs.nactive
        compile_block(stmt.body)
        code[jmp_to_call][2] = here() - jmp_to_call
        emit(OP.TFORCALL, base, 0, nnames)
        emit(OP.TFORLOOP, base, body_start - here() - 1)
        local loop = fs.loops[#fs.loops]; fs.loops[#fs.loops] = nil
        for _, j in ipairs(loop.breaks) do code[j][2] = here() - j end
        scope_restore(m1, m2, m3)
    end

    -- ---- function body ----------------------------------------------------
    -- declare parameters as locals (boxed if captured)
    for _, pname in ipairs(params) do
        local reg = fs.nactive
        fs.nactive = reg + 1
        local cap = fs.captured[pname] == true
        fs.actives[#fs.actives + 1] = { name = pname, reg = reg, captured = cap }
        if cap then emit(OP.NEWCELL, reg, reg) end
    end
    fs.freereg = fs.nactive
    if fs.maxstack < fs.nactive then fs.maxstack = fs.nactive end

    for _, stmt in ipairs(body) do compile_stmt(stmt) end
    emit(OP.RETURN, 0, 1) -- implicit return

    proto.maxstack = fs.maxstack + 2
    return proto
end

function RegCompiler.compile(source)
    local ast = Parser.parse(LuauTypes.erase(source))
    -- main chunk is a vararg function with no params
    return compile_function({}, ast.body, true, nil)
end

return RegCompiler
