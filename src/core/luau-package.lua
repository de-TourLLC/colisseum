local Entropy = require("src.core.entropy")

local Package = {}

-- ChaCha20 needs 32-bit bitwise ops. Colisseum runs under LuaJIT/Lua for builds,
-- where either bit32 (Lua 5.2+) or LuaBitOp (`bit`) is present.
local bit = bit32 or _G.bit
if not bit then error("luau-package: ChaCha20 requires bit32 or bit") end
local bxor, band, bor = bit.bxor, bit.band, bit.bor
local lshift, rshift = bit.lshift, bit.rshift
local rol = bit.lrotate or bit.rol

local MASK_MULT, MASK_INC, MASK_MOD = 1103515245, 12345, 2147483648

local function digest(value, seed)
    local state = (seed or 2166136261) % 2147483647
    for index = 1, #value do
        state = (state + value:byte(index) * 16777619) % 2147483647
        state = (state * 48271) % 2147483647
    end
    return state
end

-- Two independent 31-bit folds -> a 62-bit string of entropy for keying. Folding
-- from two seeds means distinct sources stay distinct across the wider space
-- instead of collapsing onto a single 31-bit value (reducing cross-build key
-- collisions). Kept purely integer so it runs on 32-bit Lua/LuaJIT/Luau alike.
local function wide_digest(value, seed)
    local a = digest(value, (seed or 2166136261))
    local b = digest(value, (seed or 1299721))
    return tostring(a) .. ":" .. tostring(b)
end

local function random_key(data, seed)
    -- Seed from a 62-bit fold of build entropy so distinct builds (even with the
    -- ~31-bit PRNG state elsewhere) derive well-separated key streams. Given an
    -- explicit seed this is the only input, so identical seeds reproduce the
    -- exact same key (reproducible builds); without one `seed` is already a fresh
    -- entropy-collect string unique per build.
    local state = digest(wide_digest(data, digest(tostring(seed))))
    local key = {}
    for index = 1, 32 do
        state = (state * 48271 + index * 31) % 2147483647
        key[index] = state % 256
    end
    return key
end

-- ChaCha20 keystream cipher over the bytecode bytes.
local function chacha(data, key)
    local function block(counter)
        local words = { 1634760805, 857760878, 2036477234, 1797285236 }
        for index = 1, 8 do
            local i = (index - 1) * 4 + 1
            words[#words + 1] = bor(key[i], lshift(key[i + 1], 8), lshift(key[i + 2], 16), lshift(key[i + 3], 24))
        end
        words[#words + 1] = counter
        for index = 1, 3 do
            local i = 1 + (index - 1) * 4
            words[#words + 1] = bor(key[i], lshift(key[i + 1], 8), lshift(key[i + 2], 16), lshift(key[i + 3], 24))
        end
        local original = {}
        for index = 1, 16 do original[index] = words[index] end
        local function qr(a, b, c, d)
            words[a] = words[a] + words[b]; words[d] = rol(bxor(words[d], words[a]), 16)
            words[c] = words[c] + words[d]; words[b] = rol(bxor(words[b], words[c]), 12)
            words[a] = words[a] + words[b]; words[d] = rol(bxor(words[d], words[a]), 8)
            words[c] = words[c] + words[d]; words[b] = rol(bxor(words[b], words[c]), 7)
        end
        for _ = 1, 10 do
            qr(1, 5, 9, 13); qr(2, 6, 10, 14); qr(3, 7, 11, 15); qr(4, 8, 12, 16)
            qr(1, 6, 11, 16); qr(2, 7, 12, 13); qr(3, 8, 9, 14); qr(4, 5, 10, 15)
        end
        local result = {}
        for index = 1, 16 do
            local value = original[index] + words[index]
            result[index * 4 - 3] = band(value, 255)
            result[index * 4 - 2] = band(rshift(value, 8), 255)
            result[index * 4 - 1] = band(rshift(value, 16), 255)
            result[index * 4] = band(rshift(value, 24), 255)
        end
        return result
    end
    local output = {}
    local stream, stream_counter = nil, -1
    for index = 1, #data do
        local counter = math.floor((index - 1) / 64) + 1
        if counter ~= stream_counter then stream = block(counter); stream_counter = counter end
        output[index] = bxor(data:byte(index), stream[((index - 1) % 64) + 1])
    end
    return output
end

local function mask_stream(seed, count)
    local state, out = seed % MASK_MOD, {}
    for index = 1, count do
        state = (state * MASK_MULT + MASK_INC) % MASK_MOD
        out[index] = math.floor(state / 65536) % 256
    end
    return out
end

local function array(values)
    local result = {}
    for index = 1, #values do result[index] = tostring(values[index]) end
    return "{" .. table.concat(result, ",") .. "}"
end

local function read(path)
    local file, message = io.open(path, "rb")
    if not file then return nil, message end
    local value = file:read("*a")
    file:close()
    return value
end

-- Per-build marker prefix so the emitted loader carries no fixed identifiers a
-- generic deobfuscator could scan for (no constant __fiu / _j / __bytecode).
-- Derivation is deterministic once a seed is known (reproducible builds); with
-- no explicit seed the passed seed already carries fresh entropy, so no extra
-- clock mixing is needed here either.
local function marker_prefix(seed)
    local state = digest("names", digest(tostring(seed)))
    local prefix = "coli_"
    for _ = 1, 6 do
        state = (state * 48271 + 7) % 2147483647
        prefix = prefix .. string.char(97 + state % 26)
    end
    return prefix
end

-- Rename this module's own identifiers to the per-build prefix. `underscores` is
-- "_" for the ChaCha seal (its locals are _x) or "__" for the Fiu wrapper (its
-- locals are __x). _G is preserved; embedded Fiu source / bytecode are never
-- touched because renaming is applied before they are spliced in.
local function mangle(code, underscores, prefix)
    code = code:gsub("_G", "\1")
    code = code:gsub("%f[%w_]" .. underscores .. "(%a[%w_]*)", prefix .. "%1")
    code = code:gsub("\1", "_G")
    return code
end

-- Encrypt `data` (the Luau bytecode) and return a Lua expression that reconstructs
-- and RETURNS the plaintext bytecode string at runtime. Two chained ciphers
-- (ChaCha20 under a masked key, then an offset keystream), an integrity checksum,
-- and hidden ChaCha constants -- decrypted purely with bitwise ops, never with
-- loadstring. The result is handed straight to Fiu's luau_load.
local function seal(data, seed, prefix)
    local key = random_key(data, seed)
    local payload = chacha(data, key)
    local key_text = {}
    for index = 1, #key do key_text[index] = string.char(key[index]) end
    local checksum = digest(data .. table.concat(key_text))
    local mask_seed = (digest(tostring(seed or "") .. tostring(#data)) % (MASK_MOD - 1)) + 1
    local mask = mask_stream(mask_seed, #key)
    local masked = {}
    for index = 1, #key do masked[index] = (key[index] + mask[index]) % 256 end
    local outer_seed = (digest(tostring(seed or "") .. "|L2|" .. tostring(#data)) % (MASK_MOD - 1)) + 1
    local outer_mask = mask_stream(outer_seed, #payload)
    local outer = {}
    for index = 1, #payload do outer[index] = (payload[index] + outer_mask[index]) % 256 end
    local const_key = (digest(tostring(seed or "") .. "|CC|") % 2147483646) + 1
    -- Second, seeded plaintext fold tied to the build: the loader verifies BOTH
    -- the keyed integrity checksum and this independent digest, so a patched
    -- bytecode stream (or a recomputed single checksum) still aborts.
    local fold2_seed = (digest(tostring(seed or "") .. "|F2|") % 2147483646) + 1
    local function fold2(value)
        local state = fold2_seed % 2147483647
        for index = 1, #value do state = (state * 31 + value:byte(index)) % 2147483647 end
        return state
    end
    local checksum2 = fold2(data)
    local c1 = bxor(1634760805, const_key)
    local c2 = bxor(857760878, const_key)
    local c3 = bxor(2036477234, const_key)
    local c4 = bxor(1797285236, const_key)
    local loader = ([=[(function()
local _k=%s
local _ks=%d
local _p=%s
local _h=%d
local _h2=%d
local _s2=%d
local _ps=%d
local _y=(rawget(_G,"task") or {}).wait
for _i=1,#_k do _ks=(_ks*1103515245+12345)%%2147483648;_k[_i]=(_k[_i]-(math.floor(_ks/65536)%%256))%%256 end
for _i=1,#_p do _ps=(_ps*1103515245+12345)%%2147483648;_p[_i]=(_p[_i]-(math.floor(_ps/65536)%%256))%%256;if _y and _i%%131072==0 then _y() end end
local _b=bit32 or bit
local _x=_b.bxor
local _a=_b.band
local _o=_b.bor
local _l=_b.lshift
local _r=_b.rshift
local _v=_b.lrotate or _b.rol
local _cc={%d,%d,%d,%d}
local _D=%d
local _j=function(k,c)local w={_x(_cc[1],_D),_x(_cc[2],_D),_x(_cc[3],_D),_x(_cc[4],_D)};for i=1,8 do local n=(i-1)*4+1;w[#w+1]=_o(k[n],_l(k[n+1],8),_l(k[n+2],16),_l(k[n+3],24))end;w[#w+1]=c;for i=1,3 do local n=1+(i-1)*4;w[#w+1]=_o(k[n],_l(k[n+1],8),_l(k[n+2],16),_l(k[n+3],24))end;local z={};for i=1,16 do z[i]=w[i] end;local function q(i,j,m,n)w[i]=w[i]+w[j];w[n]=_v(_x(w[n],w[i]),16);w[m]=w[m]+w[n];w[j]=_v(_x(w[j],w[m]),12);w[i]=w[i]+w[j];w[n]=_v(_x(w[n],w[i]),8);w[m]=w[m]+w[n];w[j]=_v(_x(w[j],w[m]),7)end;for i=1,10 do q(1,5,9,13);q(2,6,10,14);q(3,7,11,15);q(4,8,12,16);q(1,6,11,16);q(2,7,12,13);q(3,8,9,14);q(4,5,10,15)end;local p={};for i=1,16 do local n=z[i]+w[i];p[i*4-3]=_a(n,255);p[i*4-2]=_a(_r(n,8),255);p[i*4-1]=_a(_r(n,16),255);p[i*4]=_a(_r(n,24),255)end;return p end
local _q=function(v)local h=2166136261;for i=1,#v do h=(h+v:byte(i)*16777619)%%2147483647;h=(h*48271)%%2147483647 end;return h end
local _q2=function(v)local h=_s2;for i=1,#v do h=(h*31+v:byte(i))%%2147483647 end;return h end
local _out={}
local _w,_c=nil,-1
for _i=1,#_p do
local _n=math.floor((_i-1)/64)+1
if _n~=_c then _w=_j(_k,_n);_c=_n end
_out[_i]=string.char(_x(_p[_i],_w[((_i-1)%%64)+1]))
if _y and _i%%131072==0 then _y() end
end
local _d=table.concat(_out)
local _z={}
for _i=1,#_k do _z[_i]=string.char(_k[_i]) end
if _q(_d..table.concat(_z))~=_h or _q2(_d)~=_h2 then error("0x3E9D",0) end
return _d
end)()]=]):format(array(masked), mask_seed, array(outer), checksum, checksum2, fold2_seed, outer_seed, c1, c2, c3, c4, const_key)
    return mangle(loader, "_", prefix)
end

Package.seal = seal
Package.digest = digest

function Package.build(bytecode, fiu_source, options)
    if type(bytecode) ~= "string" or #bytecode == 0 then error("luau-package: bytecode is required") end
    if type(fiu_source) ~= "string" or #fiu_source == 0 then error("luau-package: Fiu source is required") end
    options = options or {}
    local seed = Entropy.normalize(options.seed) or Entropy.collect()
    local prefix = marker_prefix(seed)
    -- Obfuscate the embedded Fiu VM so it does not ship as readable source: strip
    -- its comments and formatting. Done before the bytecode and markers are spliced
    -- in. Token-based minification is Luau-safe; scope renaming is NOT applied here
    -- because the native renamer corrupts Luau constructs in the VM. Guarded so a
    -- transform failure never breaks the build -- it just ships readable source.
    if options.obfuscate_backend ~= false then
        local ok_min, minified = pcall(function() return require("src.steps.minify").apply(fiu_source) end)
        if ok_min and type(minified) == "string" and #minified > 0 then fiu_source = minified end
    end
    local template = [=[
local __fiu = (function()
%s
end)()
local __bytecode = %s
local __settings = __fiu.luau_newsettings()
__settings.errorHandling = true
-- Always hand the VM a real global environment: the running script's own
-- environment (getfenv(0), the Roblox/Luau globals with print, string, game, ...)
-- when available, otherwise _G. An empty table would leave every global nil.
local __environment
do
    local __getfenv = rawget(_G, "getfenv")
    __environment = (type(__getfenv) == "function" and __getfenv(0)) or _G
end
local __run, __close = __fiu.luau_load(__bytecode, __environment, __settings)
if not __run then error("luau-package: bytecode load failed", 0) end
local __ok, __a, __b, __c, __d = pcall(__run)
if __close then __close() end
if not __ok then error(__a, 0) end
return __a, __b, __c, __d
]=]
    return mangle(template, "__", prefix):format(fiu_source, seal(bytecode, seed, prefix))
end

-- Accept only a safe relative Fiu source path. Absolute paths, drive letters,
-- parent traversal (".."), and control/shell characters are rejected so a hosted
-- obfuscator cannot turn `--fiu` into a read-arbitrary-file + embed-and-run
-- primitive. A bare filename (no separators) resolves under vendor/Fiu/.
local function safe_fiu_path(path)
    if path == nil then return "vendor/Fiu/Source.lua" end
    if type(path) ~= "string" or path == "" then return nil end
    if path:find("%z") or path:find("[\r\n]") then return nil end
    local separator = package.config:sub(1, 1)
    if path:match("^[%a]:") then return nil end -- drive letter
    if path:sub(1, 1) == "/" or path:sub(1, 1) == "\\" then return nil end -- absolute
    for piece in path:gmatch("[^/\\]+") do
        if piece == ".." then return nil end
    end
    if path:find(separator) or path:find("/") then return path end
    return "vendor/Fiu/" .. path
end

function Package.from_source(source, compiler, fiu, options)
    local Compiler = require("src.core.luau-compiler")
    local safe_fiu, safe_error = safe_fiu_path(fiu)
    if not safe_fiu then return nil, "luau-package: fiu path must be a safe relative path" end
    local fiu_source, message = read(safe_fiu)
    if not fiu_source then return nil, "luau-package: " .. tostring(message) end
    local bytecode, compile_message = Compiler.compile(source, compiler, options)
    if not bytecode then return nil, compile_message end
    return Package.build(bytecode, fiu_source, options)
end

return Package
