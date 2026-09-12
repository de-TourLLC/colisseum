-- Register VM interpreter. Runs a proto tree (from reg-compiler) with reference-Lua
-- semantics; VM closures are real Lua functions. No loadstring. Lua/LuaJIT + Luau.
-- The program ships as an opaque byte blob decoded on demand; an optional `anchor`
-- arms an anti-hook sampler. Implementation details are intentionally terse.

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

-- Fibonacci (Zeckendorf) blob layer. When a build enables it, the opaque byte
-- stream is carried Fibonacci-coded and bit-packed; this rebuilds the exact fogged
-- bytes ONCE at VM start (the hot loop is untouched). Pure integer math, portable
-- across Lua 5.1 / LuaJIT / Luau. Inverse of fibonacci.encode_bytes + pack_bits.
local kk_fib = { 1, 2 }
for kk_i = 3, 15 do kk_fib[kk_i] = kk_fib[kk_i - 1] + kk_fib[kk_i - 2] end
local kk_pow2 = { [0] = 1, 2, 4, 8, 16, 32, 64, 128 }
local function fib_unpack(packed, bitlen)
    local out, count = {}, 0
    local n, i, prev, pos = 0, 1, 0, 1
    while pos <= bitlen do
        local byte_index = kk_floor((pos - 1) / 8) + 1
        local bit = kk_floor((packed:byte(byte_index) or 0) / kk_pow2[7 - ((pos - 1) % 8)]) % 2
        if bit == 1 and prev == 1 then
            count = count + 1
            out[count] = kk_char((n - 1) % 256)
            n, i, prev = 0, 1, 0
        else
            if bit == 1 then n = n + kk_fib[i] end
            prev = bit
            i = i + 1
        end
        pos = pos + 1
    end
    return kk_concat(out)
end

-- Inline RFC 8439 ChaCha20 keystream (mirror of src/core/chacha.lua). Used when a
-- build enables the real stream cipher: the fogged blob is XOR-masked with this
-- keystream, derived once at VM start (build/runtime agreement is verified by the
-- register VM differential + encrypt suites). Portable 32-bit integer math.
local kk_pow = {}
do local v = 1; for i = 0, 32 do kk_pow[i] = v; v = v * 2 end end
local function cc_add(a, b) return (a + b) % 4294967296 end
local function cc_rotl(x, n) local lo = x % kk_pow[32 - n]; return lo * kk_pow[n] + kk_floor(x / kk_pow[32 - n]) end
local function cc_qr(s, a, b, c, d)
    s[a] = cc_add(s[a], s[b]); s[d] = cc_rotl(kk_xor(s[d], s[a]) % 4294967296, 16)
    s[c] = cc_add(s[c], s[d]); s[b] = cc_rotl(kk_xor(s[b], s[c]) % 4294967296, 12)
    s[a] = cc_add(s[a], s[b]); s[d] = cc_rotl(kk_xor(s[d], s[a]) % 4294967296, 8)
    s[c] = cc_add(s[c], s[d]); s[b] = cc_rotl(kk_xor(s[b], s[c]) % 4294967296, 7)
end
local function cc_block(key, counter, nonce)
    local s = { 1634760805, 857760878, 2036477234, 1797285236,
        key[1], key[2], key[3], key[4], key[5], key[6], key[7], key[8],
        counter, nonce[1], nonce[2], nonce[3] }
    local w = {}
    for i = 1, 16 do w[i] = s[i] end
    for _ = 1, 10 do
        cc_qr(w, 1, 5, 9, 13); cc_qr(w, 2, 6, 10, 14); cc_qr(w, 3, 7, 11, 15); cc_qr(w, 4, 8, 12, 16)
        cc_qr(w, 1, 6, 11, 16); cc_qr(w, 2, 7, 12, 13); cc_qr(w, 3, 8, 9, 14); cc_qr(w, 4, 5, 10, 15)
    end
    for i = 1, 16 do w[i] = cc_add(w[i], s[i]) end
    return w
end
local function cc_derive(fog)
    local nf = #fog
    local state = 2166136261
    for i = 1, nf do state = (state + fog[i] * 16777619) % 4294967296; state = (state * 48271) % 4294967296 end
    local bytes = {}
    for i = 1, 44 do state = (state * 1103515245 + 12345) % 4294967296; bytes[i] = kk_floor(state / 65536) % 256 end
    local function word(o) return bytes[o] + bytes[o + 1] * 256 + bytes[o + 2] * 65536 + bytes[o + 3] * 16777216 end
    local key, nonce = {}, {}
    for i = 1, 8 do key[i] = word((i - 1) * 4 + 1) end
    for i = 1, 3 do nonce[i] = word(32 + (i - 1) * 4 + 1) end
    return key, nonce, 1
end
-- Fill mask[1..n] with the ChaCha20 keystream for the fog-derived key/nonce.
local function cc_fill(mask, fog, n)
    local key, nonce, counter = cc_derive(fog)
    local produced = 0
    while produced < n do
        local w = cc_block(key, counter, nonce)
        for i = 1, 16 do
            local v = w[i]; local base = produced + (i - 1) * 4
            if base + 1 <= n then mask[base + 1] = v % 256 end
            if base + 2 <= n then mask[base + 2] = kk_floor(v / 256) % 256 end
            if base + 3 <= n then mask[base + 3] = kk_floor(v / 65536) % 256 end
            if base + 4 <= n then mask[base + 4] = kk_floor(v / 16777216) % 256 end
        end
        produced = produced + 64; counter = (counter + 1) % 4294967296
    end
end

local OP = RegBytecode.OP

local Runtime = {}
Runtime.LIMITS = { steps = 2000000000, depth = 200 }

function Runtime.run(program, options)
    options = options or {}
    local globals = options.environment or _G

    local S = program.S
    -- Optional Fibonacci blob layer: program.fib is the exact bit length of the
    -- packed codeword stream. Rebuild the fogged byte stream before any offset math.
    if program.fib then S = fib_unpack(S, program.fib) end
    local regs = program.r
    local fog = program.f or { 0 }
    local nfog = #fog
    -- Optional per-build opcode normalization (raw code -> canonical). Absent in
    -- the dev path, where the raw code is already canonical.
    local onorm = program.o

    -- Honeypot drift: 0 on a clean run (results unaffected); set nonzero on tamper
    -- detection, after which numeric arithmetic results are offset by `hp`.
    local hp = 0

    -- Keystream mask, derived once at VM start (portable all-integer math; matches
    -- reg-bytecode.encode_opaque byte-for-byte). program.enc selects the real
    -- ChaCha20 stream cipher; otherwise the legacy per-position hash keystream.
    local mask = {}
    local slen = #S
    if program.enc then
        cc_fill(mask, fog, slen)
    else
        local ks_key = 5381
        for i = 1, nfog do ks_key = (ks_key * 33 + fog[i]) % 4294967296 end
        for i = 1, slen do
            local h = (i * 40503 + ks_key) % 4294967296
            h = (h * 65599 + 3266489917) % 4294967296
            h = (h + kk_floor(h / 65536)) % 4294967296
            h = (h * 40503) % 4294967296
            mask[i] = kk_xor(fog[(i - 1) % nfog + 1], kk_floor(h / 7) % 256)
        end
    end

    -- Raw fogged-byte reads. `S` is the build-fogged stream; every byte is
    -- un-fogged on demand, so the interpreter never holds decoded state ready.
    local function bget(i)
        return kk_xor(S:byte(i), mask[i])
    end
    -- Biased little-endian i32 at offset i.
    local function vget(i)
        local a, b, c, d = S:byte(i, i + 3)
        a = kk_xor(a, mask[i])
        b = kk_xor(b, mask[i + 1])
        c = kk_xor(c, mask[i + 2])
        d = kk_xor(d, mask[i + 3])
        return (a + b * 256 + c * 65536 + d * 16777216) - 2147483648
    end
    -- Unsigned little-endian u32 at offset i.
    local function uget(i)
        local a, b, c, d = S:byte(i, i + 3)
        a = kk_xor(a, mask[i])
        b = kk_xor(b, mask[i + 1])
        c = kk_xor(c, mask[i + 2])
        d = kk_xor(d, mask[i + 3])
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

    -- Startup tamper gate, bound INTO the interpreter itself (not a strippable
    -- payload guard). program.m carries decisive executor/injector marker names
    -- (assembled at build time; absent in unit builds). If a debug hook is already
    -- installed, or any one marker is present in the host environment, it latches
    -- the SAME silent honeypot drift the sampler uses: arithmetic results quietly
    -- diverge, with no branded error to point an attacker at the check. Unwinding
    -- and stripping the compiled-in anti-tamper payload still leaves this backstop.
    local marks = program.m
    if marks then
        local tripped = false
        if kk_type(anchor) == "table" and kk_type(anchor.g) == "function" then
            local okh, hooked = kk_pcall(anchor.g)
            if okh and hooked ~= nil then tripped = true end
        end
        if not tripped then
            for mi = 1, #marks do
                if globals[marks[mi]] ~= nil then tripped = true; break end
            end
        end
        if tripped then hp = 1 + (steps % 3) end
    end

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
                local tripped = (ad.gethook ~= anchor.g or ad.sethook ~= anchor.s)
                if not tripped then
                    local ok, hook = kk_pcall(ad.gethook)
                    if ok and hook ~= nil then tripped = true end
                end
                if tripped then
                    -- Divert opaquely instead of announcing detection: latch the
                    -- honeypot drift and stop sampling (the poison is now self-
                    -- sustaining, and re-checking would waste hot-loop time and
                    -- re-expose the guard's timing). No branded error ships or fires.
                    hp = 1 + (steps % 3)
                    sampler = false
                end
            end
            -- Decode the next instruction from the fogged byte stream on demand.
            local off = reg.d + (pc - 1) * 13
            local op = kk_xor(S:byte(off), mask[off])
            if onorm then op = onorm[op] end
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
            elseif op == OP.ADD then R[a] = RK(b) + RK(c) + hp
            elseif op == OP.SUB then R[a] = RK(b) - RK(c) + hp
            elseif op == OP.MUL then R[a] = RK(b) * RK(c) + hp
            elseif op == OP.DIV then R[a] = RK(b) / RK(c) + hp
            elseif op == OP.MOD then R[a] = RK(b) % RK(c) + hp
            elseif op == OP.POW then R[a] = RK(b) ^ RK(c) + hp
            elseif op == OP.IDIV then R[a] = kk_floor(RK(b) / RK(c)) + hp
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
            -- Superoperators: run this op and the next slot's op, then skip it
            -- (the second op's operands are read from off + 13).
            elseif op == OP.FUSEMM then
                R[a] = R[b]
                local o2 = off + 13
                R[vget(o2 + 1)] = R[vget(o2 + 5)]
                pc = pc + 1
            elseif op == OP.FUSELL then
                R[a] = kget(reg, b)
                local o2 = off + 13
                R[vget(o2 + 1)] = kget(reg, vget(o2 + 5))
                pc = pc + 1
            elseif op == OP.FUSEGG then
                R[a] = globals[kget(reg, b)]
                local o2 = off + 13
                R[vget(o2 + 1)] = globals[kget(reg, vget(o2 + 5))]
                pc = pc + 1
            else
                kk_error("invalid instruction", 0)
            end
        end
    end

    return execute_proto(regs[0], {}, pack())
end

return Runtime