--[[ register VM interpreter: runs a proto tree from reg-compiler; VM closures are real
     Lua functions. no loadstring. the program ships as an opaque byte blob decoded on
     demand, and an optional `anchor` arms the anti-hook sampler. ]]

local RegBytecode = require("src.core.reg-bytecode")

local unpack_fn = table.unpack or unpack
--[[ named distinctly (not `local x = x`) so the rename step can mangle the embedded
     interpreter without shadowing the right-hand globals to nil. ]]
local kk_select, kk_type, kk_error, kk_floor = select, type, error, math.floor
local kk_pcall = pcall
local kk_char, kk_concat = string.char, table.concat
local kk_tonumber = tonumber
--[[ portable byte-wise XOR (bit32 / bit / arithmetic fallback), since `~` isn't a 5.1
     operator. on the hot path: every instruction/constant byte is un-fogged on demand. ]]
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

--[[ Fibonacci blob layer: when enabled the stream is Fibonacci-coded and bit-packed;
     this rebuilds the fogged bytes once at VM start. inverse of encode_bytes+pack_bits. ]]
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

--[[ inline ChaCha20 keystream (mirror of chacha.lua). when the cipher is on, the
     fogged blob is XOR-masked with this, derived once at VM start. ]]
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
local function cc_derive(fog, cred)
    local nf = #fog
    -- mirror of ChaCha.derive in chacha.lua; keep byte-identical or the keystream drifts
    local M = 4294967296
    local a, b, c, d = 2166136261, 2246822519, 3266489917, 668265263
    for i = 1, nf do
        local x = fog[i]
        a = (a + x * 16777619) % M;  a = (a * 48271) % M
        b = (b + x * 40503 + 1) % M; b = (b * 1664525 + 1013904223) % M
        c = (c + x * 2654435761) % M; c = (c * 22695477 + 1) % M
        d = (d + x * 2246822519 + 1) % M; d = (d * 134775813 + 1) % M
    end
    -- fold the credit into the state (mirror of ChaCha.derive): the key is bound to the
    -- brand, so an edited or stripped credit derives the wrong key and the blob is garbage.
    if cred then
        for i = 1, #cred do
            local x = cred:byte(i)
            a = (a + x * 16777619) % M;  a = (a * 48271) % M
            b = (b + x * 40503 + 1) % M; b = (b * 1664525 + 1013904223) % M
            c = (c + x * 2654435761) % M; c = (c * 22695477 + 1) % M
            d = (d + x * 2246822519 + 1) % M; d = (d * 134775813 + 1) % M
        end
    end
    local bytes = {}
    for i = 1, 44 do
        a = (a * 1103515245 + 12345) % M
        b = (b * 1664525 + 1013904223) % M
        c = (c * 22695477 + 1) % M
        d = (d * 134775813 + 1) % M
        local mixed = (a + b * 7 + c * 13 + d * 17) % M
        bytes[i] = kk_floor(mixed / 256) % 256
    end
    local function word(o) return bytes[o] + bytes[o + 1] * 256 + bytes[o + 2] * 65536 + bytes[o + 3] * 16777216 end
    local key, nonce = {}, {}
    for i = 1, 8 do key[i] = word((i - 1) * 4 + 1) end
    for i = 1, 3 do nonce[i] = word(32 + (i - 1) * 4 + 1) end
    return key, nonce, 1
end
-- Fill mask[1..n] with the ChaCha20 keystream for the fog+credit-derived key/nonce.
local function cc_fill(mask, fog, n, cred)
    local key, nonce, counter = cc_derive(fog, cred)
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

--[[ inverse of reg-bytecode's keyed S-box (sbox_wrap): rebuild the same key-derived byte
     permutation from the fog and the embedded credit, then invert it. applied once at VM
     start to peel the substitution layer, so the execution hot path reads the plain
     stream-ciphered bytes with no per-byte cost. an edited or stripped credit derives the
     wrong box and the blob decodes to garbage. keep this byte-identical with sbox_build. ]]
local function sbox_inv(fog, cred)
    local M = 4294967296
    local seed = 2654435761 % M
    for i = 1, #fog do seed = (seed + fog[i] * 16777619) % M; seed = (seed * 48271) % M end
    for i = 1, #cred do seed = (seed + cred:byte(i) * 16777619) % M; seed = (seed * 48271) % M end
    local box = {}
    for i = 0, 255 do box[i] = i end
    for i = 255, 1, -1 do
        seed = (seed * 48271 + 12345) % M
        local j = kk_floor(seed / 64) % (i + 1)
        box[i], box[j] = box[j], box[i]
    end
    local inv = {}
    for v = 0, 255 do inv[box[v]] = v end
    return inv
end

local OP = RegBytecode.OP

local Runtime = {}
Runtime.LIMITS = { steps = 2000000000, depth = 200 }

function Runtime.run(program, options)
    options = options or {}
    local globals = options.environment or _G

    local S = program.S
    -- fib layer: program.fib is the packed bit length; rebuild the bytes before offset math
    if program.fib then S = fib_unpack(S, program.fib) end
    --[[ S-box layer: peel the keyed byte substitution once here (one O(n) startup pass,
         like the keystream/fib setup), leaving the stream-ciphered bytes the hot path
         already expects -- so per-instruction execution speed is unchanged. ]]
    if program.sb then
        local inv = sbox_inv(program.f or { 0 }, program.c or "")
        local t = {}
        for i = 1, #S do t[i] = kk_char(inv[S:byte(i)]) end
        S = kk_concat(t)
    end
    local regs = program.r
    local fog = program.f or { 0 }
    local nfog = #fog
    -- per-build opcode normalization (raw -> canonical); absent in the dev path
    local onorm = program.o

    -- honeypot drift: 0 on a clean run; set nonzero on tamper, offsetting numeric results by hp
    local hp = 0

    --[[ keystream mask, derived once at VM start (all-integer, matches encode_opaque
         byte-for-byte). program.enc = real ChaCha20; else the legacy hash keystream. ]]
    local mask = {}
    local slen = #S
    -- the embedded credit feeds the keystream; nil/"" leaves it unchanged (dev builds)
    local cred = program.c or ""
    if program.enc then
        cc_fill(mask, fog, slen, cred)
    else
        local ks_key = 5381
        for i = 1, nfog do ks_key = (ks_key * 33 + fog[i]) % 4294967296 end
        for i = 1, #cred do ks_key = (ks_key * 33 + cred:byte(i)) % 4294967296 end
        for i = 1, slen do
            local h = (i * 40503 + ks_key) % 4294967296
            h = (h * 65599 + 3266489917) % 4294967296
            h = (h + kk_floor(h / 65536)) % 4294967296
            h = (h * 40503) % 4294967296
            mask[i] = kk_xor(fog[(i - 1) % nfog + 1], kk_floor(h / 7) % 256)
        end
    end

    -- raw fogged-byte reads: every byte un-fogged on demand, no decoded state kept
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
    --[[ optional constant cache (program.kc / --cache): decode each constant from the
         blob once and keep it, instead of rebuilding it on every access -- big win in
         constant-heavy loops. off by default, so max-security builds keep decode-on-
         demand. keyed by the constant's blob offset. ]]
    local kcache = program.kc and {} or nil
    local function kget(reg, ki)
        local off = reg.o[ki]
        if kcache then
            local cached = kcache[off]
            if cached ~= nil then return cached end
        end
        local t = bget(off)
        local v
        if t == 0 then v = kk_tonumber(sget(off + 1))
        elseif t == 1 then v = sget(off + 1)
        elseif t == 2 then v = (bget(off + 1) == 1) end
        if kcache then kcache[off] = v end
        return v
    end

    local step_limit = options.steps or Runtime.LIMITS.steps
    local steps = 0

    --[[ cooperative auto-yield so a heavy loop doesn't trip Roblox's execution-time
         limit: breathe every `yield_interval` instructions when a scheduler yield
         exists and coroutine.isyieldable() allows. off (0) by default. ]]
    local yield_interval = options.yield_interval or 0
    local yield_fn
    if yield_interval > 0 then
        local t = globals.task
        if kk_type(t) == "table" and kk_type(t.wait) == "function" then yield_fn = t.wait
        elseif kk_type(globals.wait) == "function" then yield_fn = globals.wait end
    end
    local isyieldable = coroutine.isyieldable
    local next_yield = yield_interval

    --[[ anti-hook sampler, armed only when the bundle passed an anchor. the dispatch
         loop periodically re-checks, on a jittered stride, that no hook is installed
         and the debug API is still the captured original. ]]
    local anchor = options.anchor
    local sampler = kk_type(anchor) == "table" and kk_type(anchor.d) == "table"
        and kk_type(anchor.g) == "function"
    local sample_at = 1024

    --[[ startup tamper gate bound into the interpreter. program.m carries executor
         marker names; a debug hook at start, or any marker in the host env, latches the
         same silent drift the sampler uses (arithmetic diverges, no branded error). ]]
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

    --[[ self-hash: rehash the shipped blob and latch the silent drift if it no longer
         matches the value baked at build, so an in-memory patch quietly corrupts
         results. mirrors register-vm's blob_hash over the raw program.S. ]]
    if program.h then
        local ps = program.S
        local h = 2166136261 % 2147483647
        for i = 1, #ps do
            h = (h + ps:byte(i) * 16777619) % 2147483647
            h = (h * 48271) % 2147483647
        end
        if h ~= program.h then hp = 1 + (steps % 3) end
    end

    --[[ brand gate: hash the embedded credit and latch the drift if it was edited or
         removed, so the attribution can't be stripped without corrupting results. ]]
    if program.cr then
        local c = program.c or ""
        local h = 2166136261 % 2147483647
        for i = 1, #c do
            h = (h + c:byte(i) * 16777619) % 2147483647
            h = (h * 48271) % 2147483647
        end
        if h ~= program.cr then hp = 1 + (steps % 3) end
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
                    -- Latch the drift and stop sampling instead of announcing it; the
                    -- poison is self-sustaining and re-checking would waste time.
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
            --[[ native operators, so overloaded types (Vector3/CFrame/...) dispatch
                 through their metamethods. the drift touches numbers only, so a clean
                 run (hp==0) never follows v1+v2 with a +0 that would re-run __add. ]]
            elseif op == OP.ADD then local v = RK(b) + RK(c); if hp ~= 0 and kk_type(v) == "number" then v = v + hp end; R[a] = v
            elseif op == OP.SUB then local v = RK(b) - RK(c); if hp ~= 0 and kk_type(v) == "number" then v = v + hp end; R[a] = v
            elseif op == OP.MUL then local v = RK(b) * RK(c); if hp ~= 0 and kk_type(v) == "number" then v = v + hp end; R[a] = v
            elseif op == OP.DIV then local v = RK(b) / RK(c); if hp ~= 0 and kk_type(v) == "number" then v = v + hp end; R[a] = v
            elseif op == OP.MOD then local v = RK(b) % RK(c); if hp ~= 0 and kk_type(v) == "number" then v = v + hp end; R[a] = v
            elseif op == OP.POW then local v = RK(b) ^ RK(c); if hp ~= 0 and kk_type(v) == "number" then v = v + hp end; R[a] = v
            elseif op == OP.IDIV then local v = kk_floor(RK(b) / RK(c)); if hp ~= 0 and kk_type(v) == "number" then v = v + hp end; R[a] = v
            elseif op == OP.CONCAT then R[a] = RK(b) .. RK(c)
            elseif op == OP.EQ then R[a] = RK(b) == RK(c)
            elseif op == OP.NE then R[a] = RK(b) ~= RK(c)
            elseif op == OP.LT then R[a] = RK(b) < RK(c)
            elseif op == OP.LE then R[a] = RK(b) <= RK(c)
            elseif op == OP.GT then R[a] = RK(b) > RK(c)
            elseif op == OP.GE then R[a] = RK(b) >= RK(c)
            elseif op == OP.NOT then local x = RK(b); R[a] = (x == nil or x == false)
            elseif op == OP.NEG then R[a] = -RK(b)
            elseif op == OP.LEN then
                -- honor __len (5.1 ignores it, Luau invokes it) to match the target
                local _x = RK(b); local _mt = getmetatable(_x)
                if _mt and _mt.__len then R[a] = _mt.__len(_x) else R[a] = #_x end
            elseif op == OP.JMP then pc = pc + a
            elseif op == OP.TEST then
                local x = R[a]; local truth = (x ~= nil and x ~= false)
                if truth ~= (b ~= 0) then pc = pc + 1 end
            elseif op == OP.CALL then
                local n = (b == 0) and (top - a - 1) or (b - 1)
                local args = {}
                for i = 1, n do args[i] = R[a + i] end
                local func = R[a]
                if kk_type(func) ~= "function" then
                    -- callable object? (__call) let the native call run it; else error
                    local mt = getmetatable(func)
                    if not (mt and mt.__call) then kk_error("attempt to call a " .. kk_type(func) .. " value", 0) end
                end
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
            elseif op == OP.FUSEML then
                R[a] = R[b]
                local o2 = off + 13
                R[vget(o2 + 1)] = kget(reg, vget(o2 + 5))
                pc = pc + 1
            elseif op == OP.FUSELM then
                R[a] = kget(reg, b)
                local o2 = off + 13
                R[vget(o2 + 1)] = R[vget(o2 + 5)]
                pc = pc + 1
            elseif op == OP.FUSEMG then
                R[a] = R[b]
                local o2 = off + 13
                R[vget(o2 + 1)] = globals[kget(reg, vget(o2 + 5))]
                pc = pc + 1
            elseif op == OP.FUSEGM then
                R[a] = globals[kget(reg, b)]
                local o2 = off + 13
                R[vget(o2 + 1)] = R[vget(o2 + 5)]
                pc = pc + 1
            elseif op == OP.FUSELG then
                R[a] = kget(reg, b)
                local o2 = off + 13
                R[vget(o2 + 1)] = globals[kget(reg, vget(o2 + 5))]
                pc = pc + 1
            elseif op == OP.FUSEGL then
                R[a] = globals[kget(reg, b)]
                local o2 = off + 13
                R[vget(o2 + 1)] = kget(reg, vget(o2 + 5))
                pc = pc + 1
            else
                kk_error("invalid instruction", 0)
            end
        end
    end

    return execute_proto(regs[0], {}, pack())
end

return Runtime