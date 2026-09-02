-- Register VM interpreter. Executes a proto tree produced by reg-compiler. Uses
-- raw Lua operators for arithmetic/compare/index/concat, so semantics (coercion,
-- metamethods, errors) match reference Lua exactly. VM closures are REAL Lua
-- functions, so host code (pcall, table.sort, ipairs, metamethods) calls them
-- directly. No loadstring. Runs on Lua/LuaJIT and Luau.
--
-- In-memory hardening: the decoded program never materializes as plain Lua
-- tables. `program` is a blob { S = <build-fogged byte stream>, f = <fog>,
-- r = <numeric region index> }; every instruction and constant is decoded from
-- the byte stream on demand inside the dispatch loop, so a debug.getupvalue /
-- getinfo dump of an active interpreter frame yields an undecoded, fogged blob --
-- not a ready-to-read {code, constants, protos} tree.
--
-- An optional `anchor` (the host debug table, gethook and sethook captured at
-- bundle load) drives a stride-jittered anti-hook sampler that runs INSIDE the
-- dispatch loop: it aborts the moment a debug hook is installed post-boot or the
-- debug API functions are swapped, so a step-hook that waits for the guard to
-- pass (then sethook's a count hook to scoop upvalues) trips the VM mid-run.

local RegBytecode = require("src.core.reg-bytecode")

local unpack_fn = table.unpack or unpack
-- Localized under distinct names (not `local x = x`) so the rename step can mangle
-- this interpreter when it is embedded, without the self-shadowing that would rename
-- the right-hand globals to nil.
local kk_select, kk_type, kk_error, kk_floor = select, type, error, math.floor
local kk_pcall = pcall
local kk_char, kk_concat = string.char, table.concat
local kk_tonumber = tonumber
-- Portable byte-wise XOR (bit32 / bit / arithmetic fallback) since `~` is not a
-- Lua 5.1 operator. Required on the hot path: every instruction/constant byte is
-- un-foged on demand in the dispatch loop.
local kk_xor
do
    local b32 = bit32 or rawget(_G, "bit") or rawget(_G, "bit32")
    if b32 and type(b32.bxor) == "function" then
        kk_xor = b32.bxor
    else
        kk_xor = function(a, b)
            local r, p = 0, 1
            while (a > 0) or (b > 0) do
                local ba, bb = a % 2, b % 2
                if ba ~= bb then r = r + p end
                if a > 0 then a = (a - ba) / 2 end
                if b > 0 then b = (b - bb) / 2 end
                p = p * 2
            end
            return r
        end
    end
end
local function pack(...) return { n = kk_select("#", ...), ... } end

local OP = RegBytecode.OP

local Runtime = {}
Runtime.LIMITS = { steps = 2000000000, depth = 200 }

function Runtime.run(program, options)
    options = options or {}
    local globals = options.environment or _G

    local S = program.S
    local regs = program.r
    local fog = program.f or { 0 }
    local nfog = #fog

    -- Raw fogged-byte reads. `S` is the build-fogged stream; every byte is
    -- un-fogged on demand, so the interpreter never holds decoded state ready.
    local function bget(i)
        return kk_xor(S:byte(i), fog[(i - 1) % nfog + 1])
    end
    -- Biased little-endian i32 at offset i.
    local function vget(i)
        local a, b, c, d = S:byte(i, i + 3)
        local j = i - 1
        a = kk_xor(a, fog[j % nfog + 1])
        b = kk_xor(b, fog[(j + 1) % nfog + 1])
        c = kk_xor(c, fog[(j + 2) % nfog + 1])
        d = kk_xor(d, fog[(j + 3) % nfog + 1])
        return (a + b * 256 + c * 65536 + d * 16777216) - 2147483648
    end
    -- Unsigned little-endian u32 at offset i.
    local function uget(i)
        local a, b, c, d = S:byte(i, i + 3)
        local j = i - 1
        a = kk_xor(a, fog[j % nfog + 1])
        b = kk_xor(b, fog[(j + 1) % nfog + 1])
        c = kk_xor(c, fog[(j + 2) % nfog + 1])
        d = kk_xor(d, fog[(j + 3) % nfog + 1])
        return a + b * 256 + c * 65536 + d * 16777216
    end
    -- Length-prefixed string at offset i (rebuilt byte-by-byte from the blob).
    local function sget(i)
        local n = uget(i)
        local out = {}
        for k = 1, n do out[k] = kk_char(bget(i + 4 + k - 1)) end
        return kk_concat(out)
    end
    -- Typed constant pool accessor (region id -> constant index).
    local function kget(reg, ki)
        local off = reg.o[ki]
        local t = bget(off)
        if t == 0 then
            return kk_tonumber(sget(off + 1))
        elseif t == 1 then
            return sget(off + 1)
        elseif t == 2 then
            return bget(off + 1) == 1
        end
        return nil
    end

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

    -- Anti-hook sampler. Only armed when the bundle passed an anchor (the host
    -- debug table captured at load): then the dispatch loop periodically
    -- re-verifies that no hook is installed and that the debug API functions are
    -- still the captured originals (so stubbing gethook to hide a live hook is
    -- itself detected). Jittered stride so an attacker cannot time around a fixed
    -- sampling interval.
    local anchor = options.anchor
    local sampler = kk_type(anchor) == "table" and kk_type(anchor.d) == "table"
        and kk_type(anchor.g) == "function"
    local sample_at = 1024

    local execute_proto  -- forward

    -- Build a real Lua function for a compiled proto capturing its upvalue cells.
    local function make_closure(reg, upvals)
        return function(...)
            local res = execute_proto(reg, upvals, pack(...))
            return unpack_fn(res, 1, res.n)
        end
    end

    execute_proto = function(reg, upvals, argpack)
        local nparams = reg.n
        local R = {}
        local nargs = argpack.n
        for i = 0, nparams - 1 do R[i] = argpack[i + 1] end
        local varargs, nva
        if reg.v == 1 then
            nva = nargs - nparams
            if nva < 0 then nva = 0 end
            varargs = {}
            for i = 1, nva do varargs[i] = argpack[nparams + i] end
        else
            nva = 0
        end

        -- RK: negative -> constant, else register.
        local function RK(x) if x < 0 then return kget(reg, -x) else return R[x] end end

        local pc = 1
        local top = 0
        while true do
            steps = steps + 1
            if steps > step_limit then kk_error("script exhausted allowed execution time", 0) end
            if yield_fn and steps >= next_yield then
                next_yield = steps + yield_interval
                if isyieldable and isyieldable() then yield_fn() end
            end
            if sampler and steps >= sample_at then
                sample_at = sample_at + 512 + ((sample_at * 48271) % 1009)
                local ad = anchor.d
                if ad.gethook ~= anchor.g or ad.sethook ~= anchor.s then
                    kk_error("ᴄᴏʟɪѕѕᴇᴜᴍ ︱ Oh Noes!, An error ocurred: 0x2175", 0)
                end
                local ok, hook = kk_pcall(ad.gethook)
                if ok and hook ~= nil then
                    kk_error("ᴄᴏʟɪѕѕᴇᴜᴍ ︱ Oh Noes!, An error ocurred: 0x2175", 0)
                end
            end
            -- Decode the next instruction from the fogged byte stream on demand.
            local off = reg.d + (pc - 1) * 13
            local op = kk_xor(S:byte(off), fog[(off - 1) % nfog + 1])
            local a = vget(off + 1)
            local b = vget(off + 5)
            local c = vget(off + 9)
            pc = pc + 1

            if op == OP.MOVE then R[a] = R[b]
            elseif op == OP.LOADK then R[a] = kget(reg, b)
            elseif op == OP.LOADNIL then R[a] = nil
            elseif op == OP.LOADBOOL then R[a] = b ~= 0
            elseif op == OP.GETGLOBAL then R[a] = globals[kget(reg, b)]
            elseif op == OP.SETGLOBAL then globals[kget(reg, b)] = R[a]
            elseif op == OP.GETUPVAL then R[a] = upvals[b][1]
            elseif op == OP.SETUPVAL then upvals[b][1] = R[a]
            elseif op == OP.NEWCELL then R[a] = { R[b] }
            elseif op == OP.GETCELL then R[a] = R[b][1]
            elseif op == OP.SETCELL then R[b][1] = R[a]
            elseif op == OP.NEWTABLE then R[a] = {}
            elseif op == OP.SETLIST then
                local tbl = R[a]
                for i = 0, top - b - 1 do tbl[c + 1 + i] = R[b + i] end
            elseif op == OP.GETTABLE then R[a] = R[b][RK(c)]
            elseif op == OP.SETTABLE then R[a][RK(b)] = RK(c)
            elseif op == OP.SELF then local o = R[b]; R[a + 1] = o; R[a] = o[RK(c)]
            elseif op == OP.ADD then R[a] = RK(b) + RK(c)
            elseif op == OP.SUB then R[a] = RK(b) - RK(c)
            elseif op == OP.MUL then R[a] = RK(b) * RK(c)
            elseif op == OP.DIV then R[a] = RK(b) / RK(c)
            elseif op == OP.MOD then R[a] = RK(b) % RK(c)
            elseif op == OP.POW then R[a] = RK(b) ^ RK(c)
            elseif op == OP.IDIV then R[a] = kk_floor(RK(b) / RK(c))
            elseif op == OP.CONCAT then R[a] = RK(b) .. RK(c)
            elseif op == OP.EQ then R[a] = RK(b) == RK(c)
            elseif op == OP.NE then R[a] = RK(b) ~= RK(c)
            elseif op == OP.LT then R[a] = RK(b) < RK(c)
            elseif op == OP.LE then R[a] = RK(b) <= RK(c)
            elseif op == OP.GT then R[a] = RK(b) > RK(c)
            elseif op == OP.GE then R[a] = RK(b) >= RK(c)
            elseif op == OP.NOT then local x = RK(b); R[a] = (x == nil or x == false)
            elseif op == OP.NEG then R[a] = -RK(b)
            elseif op == OP.LEN then R[a] = #RK(b)
            elseif op == OP.JMP then pc = pc + a
            elseif op == OP.TEST then
                local x = R[a]; local truth = (x ~= nil and x ~= false)
                if truth ~= (b ~= 0) then pc = pc + 1 end
            elseif op == OP.CALL then
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
            elseif op == OP.RETURN then
                local n = (b == 0) and (top - a) or (b - 1)
                local res = { n = n }
                for i = 0, n - 1 do res[i + 1] = R[a + i] end
                return res
            elseif op == OP.VARARG then
                if b == 0 then
                    for i = 1, nva do R[a + i - 1] = varargs[i] end
                    top = a + nva
                else
                    for i = 1, b - 1 do R[a + i - 1] = varargs[i] end
                end
            elseif op == OP.CLOSURE then
                local creg = regs[reg.p[b]]
                local caps = {}
                local descs = creg.u
                for u = 1, #descs do
                    local d = descs[u]
                    if d[1] == 0 then caps[u] = R[d[2]] else caps[u] = upvals[d[2]] end
                end
                R[a] = make_closure(creg, caps)
            elseif op == OP.FORPREP then
                local init = R[a] + 0; local limit = R[a + 1] + 0; local step = R[a + 2] + 0
                R[a] = init - step; R[a + 1] = limit; R[a + 2] = step
                pc = pc + b
            elseif op == OP.FORLOOP then
                local step = R[a + 2]; local idx = R[a] + step
                local limit = R[a + 1]
                if (step >= 0 and idx <= limit) or (step < 0 and idx >= limit) then
                    R[a] = idx; R[a + 3] = idx; pc = pc + b
                end
            elseif op == OP.TFORCALL then
                local f, st, ctl = R[a], R[a + 1], R[a + 2]
                local rets = pack(f(st, ctl))
                for i = 1, c do R[a + 2 + i] = rets[i] end
            elseif op == OP.TFORLOOP then
                if R[a + 3] ~= nil then R[a + 2] = R[a + 3]; pc = pc + b end
            else
                kk_error("invalid instruction", 0)
            end
        end
    end

    return execute_proto(regs[0], {}, pack())
end

return Runtime