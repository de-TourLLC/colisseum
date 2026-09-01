-- Register VM interpreter. Executes a proto tree produced by reg-compiler. Uses
-- raw Lua operators for arithmetic/compare/index/concat, so semantics (coercion,
-- metamethods, errors) match reference Lua exactly. VM closures are REAL Lua
-- functions, so host code (pcall, table.sort, ipairs, metamethods) calls them
-- directly. No loadstring. Runs on Lua/LuaJIT and Luau.

local RegBytecode = require("src.core.reg-bytecode")

local unpack_fn = table.unpack or unpack
-- Localized under distinct names (not `local x = x`) so the rename step can mangle
-- this interpreter when it is embedded, without the self-shadowing that would rename
-- the right-hand globals to nil.
local kk_select, kk_type, kk_error, kk_floor = select, type, error, math.floor
local function pack(...) return { n = kk_select("#", ...), ... } end

local OP = RegBytecode.OP
-- Cache opcode ids as locals for fast dispatch comparisons.
local MOVE,LOADK,LOADNIL,LOADBOOL,GETGLOBAL,SETGLOBAL,GETUPVAL,SETUPVAL,NEWCELL,GETCELL,SETCELL,
      NEWTABLE,GETTABLE,SETTABLE,SETLIST,ADD,SUB,MUL,DIV,MOD,POW,IDIV,CONCAT,
      EQ,NE,LT,LE,GT,GE,NOT,NEG,LEN,JMP,TEST,CALL,RETURN,VARARG,CLOSURE,SELF,
      FORPREP,FORLOOP,TFORCALL,TFORLOOP =
      OP.MOVE,OP.LOADK,OP.LOADNIL,OP.LOADBOOL,OP.GETGLOBAL,OP.SETGLOBAL,OP.GETUPVAL,OP.SETUPVAL,OP.NEWCELL,OP.GETCELL,OP.SETCELL,
      OP.NEWTABLE,OP.GETTABLE,OP.SETTABLE,OP.SETLIST,OP.ADD,OP.SUB,OP.MUL,OP.DIV,OP.MOD,OP.POW,OP.IDIV,OP.CONCAT,
      OP.EQ,OP.NE,OP.LT,OP.LE,OP.GT,OP.GE,OP.NOT,OP.NEG,OP.LEN,OP.JMP,OP.TEST,OP.CALL,OP.RETURN,OP.VARARG,OP.CLOSURE,OP.SELF,
      OP.FORPREP,OP.FORLOOP,OP.TFORCALL,OP.TFORLOOP

local Runtime = {}
Runtime.LIMITS = { steps = 2000000000, depth = 200 }

function Runtime.run(mainproto, options)
    options = options or {}
    local globals = options.environment or _G
    local step_limit = options.steps or Runtime.LIMITS.steps
    local steps = 0

    -- Cooperative auto-yield: on Roblox a heavy synchronous loop would hit
    -- "exhausted allowed execution time". If a scheduler yield (task.wait / wait)
    -- exists, the VM breathes every `yield_interval` instructions -- but only when
    -- `coroutine.isyieldable()` says it is legal right now (never inside a
    -- metamethod / C-call boundary). Off (0) by default and a no-op where no
    -- scheduler exists, so plain Lua/LuaJIT and light scripts pay nothing.
    local yield_interval = options.yield_interval or 0
    local yield_fn
    if yield_interval > 0 then
        local t = globals.task
        if kk_type(t) == "table" and kk_type(t.wait) == "function" then yield_fn = t.wait
        elseif kk_type(globals.wait) == "function" then yield_fn = globals.wait end
    end
    local isyieldable = coroutine.isyieldable
    local next_yield = yield_interval

    local execute_proto  -- forward

    -- Build a real Lua function for a compiled proto capturing its upvalue cells.
    local function make_closure(proto, upvals)
        return function(...)
            local res = execute_proto(proto, upvals, pack(...))
            return unpack_fn(res, 1, res.n)
        end
    end

    execute_proto = function(proto, upvals, argpack)
        local code = proto.code
        local K = proto.constants
        local protos = proto.protos
        local numparams = proto.numparams
        local R = {}
        local nargs = argpack.n
        for i = 0, numparams - 1 do R[i] = argpack[i + 1] end
        local varargs, nva
        if proto.is_vararg then
            nva = nargs - numparams
            if nva < 0 then nva = 0 end
            varargs = {}
            for i = 1, nva do varargs[i] = argpack[numparams + i] end
        else
            nva = 0
        end

        -- RK: negative -> constant, else register.
        local function RK(x) if x < 0 then return K[-x] else return R[x] end end

        local pc = 1
        local top = 0
        while true do
            steps = steps + 1
            if steps > step_limit then kk_error("script exhausted allowed execution time", 0) end
            if yield_fn and steps >= next_yield then
                next_yield = steps + yield_interval
                if isyieldable and isyieldable() then yield_fn() end
            end
            local inst = code[pc]; pc = pc + 1
            local op = inst[1]

            if op == MOVE then R[inst[2]] = R[inst[3]]
            elseif op == LOADK then R[inst[2]] = K[inst[3]]
            elseif op == LOADNIL then R[inst[2]] = nil
            elseif op == LOADBOOL then R[inst[2]] = inst[3] ~= 0
            elseif op == GETGLOBAL then R[inst[2]] = globals[K[inst[3]]]
            elseif op == SETGLOBAL then globals[K[inst[3]]] = R[inst[2]]
            elseif op == GETUPVAL then R[inst[2]] = upvals[inst[3]][1]
            elseif op == SETUPVAL then upvals[inst[3]][1] = R[inst[2]]
            elseif op == NEWCELL then R[inst[2]] = { R[inst[3]] }
            elseif op == GETCELL then R[inst[2]] = R[inst[3]][1]
            elseif op == SETCELL then R[inst[3]][1] = R[inst[2]]
            elseif op == NEWTABLE then R[inst[2]] = {}
            elseif op == SETLIST then
                local a, b, c = inst[2], inst[3], inst[4]
                local tbl = R[a]
                for i = 0, top - b - 1 do tbl[c + 1 + i] = R[b + i] end
            elseif op == GETTABLE then R[inst[2]] = R[inst[3]][RK(inst[4])]
            elseif op == SETTABLE then R[inst[2]][RK(inst[3])] = RK(inst[4])
            elseif op == SELF then local o = R[inst[3]]; R[inst[2] + 1] = o; R[inst[2]] = o[RK(inst[4])]
            elseif op == ADD then R[inst[2]] = RK(inst[3]) + RK(inst[4])
            elseif op == SUB then R[inst[2]] = RK(inst[3]) - RK(inst[4])
            elseif op == MUL then R[inst[2]] = RK(inst[3]) * RK(inst[4])
            elseif op == DIV then R[inst[2]] = RK(inst[3]) / RK(inst[4])
            elseif op == MOD then R[inst[2]] = RK(inst[3]) % RK(inst[4])
            elseif op == POW then R[inst[2]] = RK(inst[3]) ^ RK(inst[4])
            elseif op == IDIV then R[inst[2]] = kk_floor(RK(inst[3]) / RK(inst[4]))
            elseif op == CONCAT then R[inst[2]] = RK(inst[3]) .. RK(inst[4])
            elseif op == EQ then R[inst[2]] = RK(inst[3]) == RK(inst[4])
            elseif op == NE then R[inst[2]] = RK(inst[3]) ~= RK(inst[4])
            elseif op == LT then R[inst[2]] = RK(inst[3]) < RK(inst[4])
            elseif op == LE then R[inst[2]] = RK(inst[3]) <= RK(inst[4])
            elseif op == GT then R[inst[2]] = RK(inst[3]) > RK(inst[4])
            elseif op == GE then R[inst[2]] = RK(inst[3]) >= RK(inst[4])
            elseif op == NOT then local x = RK(inst[3]); R[inst[2]] = (x == nil or x == false)
            elseif op == NEG then R[inst[2]] = -RK(inst[3])
            elseif op == LEN then R[inst[2]] = #RK(inst[3])
            elseif op == JMP then pc = pc + inst[2]
            elseif op == TEST then
                local x = R[inst[2]]; local truth = (x ~= nil and x ~= false)
                if truth ~= (inst[3] ~= 0) then pc = pc + 1 end
            elseif op == CALL then
                local a, b, c = inst[2], inst[3], inst[4]
                local n = (b == 0) and (top - a - 1) or (b - 1)
                local args = {}
                for i = 1, n do args[i] = R[a + i] end
                local func = R[a]
                if kk_type(func) ~= "function" then kk_error("attempt to call a " .. kk_type(func) .. " value", 0) end
                local rets = pack(func(unpack_fn(args, 1, n)))
                local nres = rets.n
                if c == 0 then
                    for i = 0, nres - 1 do R[a + i] = rets[i + 1] end
                    top = a + nres
                else
                    for i = 0, c - 2 do R[a + i] = rets[i + 1] end
                end
            elseif op == RETURN then
                local a, b = inst[2], inst[3]
                local n = (b == 0) and (top - a) or (b - 1)
                local res = { n = n }
                for i = 0, n - 1 do res[i + 1] = R[a + i] end
                return res
            elseif op == VARARG then
                local a, b = inst[2], inst[3]
                if b == 0 then
                    for i = 1, nva do R[a + i - 1] = varargs[i] end
                    top = a + nva
                else
                    for i = 1, b - 1 do R[a + i - 1] = varargs[i] end
                end
            elseif op == CLOSURE then
                local child = protos[inst[3]]
                local caps = {}
                local descs = child.upvals
                for u = 1, #descs do
                    local d = descs[u]
                    if d.kind == "local" then caps[u] = R[d.index] else caps[u] = upvals[d.index] end
                end
                R[inst[2]] = make_closure(child, caps)
            elseif op == FORPREP then
                local a = inst[2]
                local init = R[a] + 0; local limit = R[a + 1] + 0; local step = R[a + 2] + 0
                R[a] = init - step; R[a + 1] = limit; R[a + 2] = step
                pc = pc + inst[3]
            elseif op == FORLOOP then
                local a = inst[2]
                local step = R[a + 2]; local idx = R[a] + step
                local limit = R[a + 1]
                if (step >= 0 and idx <= limit) or (step < 0 and idx >= limit) then
                    R[a] = idx; R[a + 3] = idx; pc = pc + inst[3]
                end
            elseif op == TFORCALL then
                local a, c = inst[2], inst[4]
                local f, st, ctl = R[a], R[a + 1], R[a + 2]
                local rets = pack(f(st, ctl))
                for i = 1, c do R[a + 2 + i] = rets[i] end
            elseif op == TFORLOOP then
                local a = inst[2]
                if R[a + 3] ~= nil then R[a + 2] = R[a + 3]; pc = pc + inst[3] end
            else
                kk_error("invalid instruction", 0)
            end
        end
    end

    return execute_proto(mainproto, {}, pack())
end

return Runtime
