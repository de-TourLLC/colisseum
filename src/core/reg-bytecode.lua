-- Register VM instruction set. A compiled program is a tree of protos; each proto
-- holds a flat instruction stream, a constants pool, child protos (for closures),
-- and upvalue descriptors. Instructions are arrays { opcode, a, b, c } so the
-- interpreter reads them with cheap numeric indexing.
--
-- Registers are a flat per-frame array R[0..maxstack-1]. Locals occupy low slots;
-- temporaries are allocated above them. A local that is captured by a nested
-- closure is "boxed": its register holds a one-element cell { value } and the
-- ...CELL opcodes read/write through it, so the closure and its parent share the
-- same storage (correct upvalue semantics without open/closed upvalue machinery).
--
-- RK operands: a compiler operand tagged as a constant is encoded as -(kidx+1)
-- (negative) so a single field can name either a register (>=0) or a constant.

local RegBytecode = {}

-- Contiguous opcode numbering (1..N) so a later obfuscation step can permute it.
local names = {
    "MOVE",       -- a,b      R[a] = R[b]
    "LOADK",      -- a,b      R[a] = K[b]
    "LOADNIL",    -- a        R[a] = nil
    "LOADBOOL",   -- a,b      R[a] = (b ~= 0)
    "GETGLOBAL",  -- a,b      R[a] = G[K[b]]
    "SETGLOBAL",  -- a,b      G[K[b]] = R[a]
    "GETUPVAL",   -- a,b      R[a] = upvalue b (a cell): value = U[b][1]
    "SETUPVAL",   -- a,b      U[b][1] = R[a]
    "NEWCELL",    -- a,b      R[a] = { R[b] }   (box a value into a fresh cell)
    "GETCELL",    -- a,b      R[a] = R[b][1]    (read a boxed local)
    "SETCELL",    -- a,b      R[b][1] = R[a]    (write a boxed local; a is source)
    "NEWTABLE",   -- a        R[a] = {}
    "GETTABLE",   -- a,b,c    R[a] = R[b][RK(c)]
    "SETTABLE",   -- a,b,c    R[a][RK(b)] = RK(c)
    "SETLIST",    -- a,b,c    R[a][c+i] = R[b+i-1] for i=1..? (array init; see compiler)
    "ADD", "SUB", "MUL", "DIV", "MOD", "POW", "IDIV", "CONCAT", -- a,b,c  R[a]=RK(b) op RK(c)
    "EQ", "NE", "LT", "LE", "GT", "GE",                        -- a,b,c  R[a]=RK(b) rel RK(c)
    "NOT", "NEG", "LEN",   -- a,b      R[a] = op RK(b)
    "JMP",        -- a       pc += a
    "TEST",       -- a,b     if truthy(R[a]) ~= (b~=0) then pc = pc + 1 (skip next JMP)
    "CALL",       -- a,b,c   call R[a] with b-1 args at R[a+1..]; want c-1 results (c==0: all) at R[a..]
    "RETURN",     -- a,b     return R[a..a+b-2]; b==0 -> to top of stack
    "VARARG",     -- a,b     R[a..a+b-2] = ...; b==0 -> all, adjust top
    "CLOSURE",    -- a,b     R[a] = closure(protos[b])
    "SELF",       -- a,b,c   R[a+1]=R[b]; R[a]=R[b][RK(c)]  (method receiver + lookup)
    "FORPREP",    -- a,b     numeric-for init; R[a]=index,R[a+1]=limit,R[a+2]=step; pc+=b
    "FORLOOP",    -- a,b     numeric-for step/test; if continuing R[a+3]=index, pc+=b
    "TFORCALL",   -- a,c     generic-for: call R[a] with R[a+1],R[a+2]; c results at R[a+3..]
    "TFORLOOP",   -- a,b     if R[a+3]~=nil then R[a+2]=R[a+3]; pc+=b
}

local by_name, by_code = {}, {}
for code, name in ipairs(names) do by_name[name] = code; by_code[code] = name end

RegBytecode.OP = by_name          -- OP.MOVE == 1, ...
RegBytecode.NAME = by_code        -- NAME[1] == "MOVE"
RegBytecode.COUNT = #names

function RegBytecode.opcodes()
    local result = {}
    for name, code in pairs(by_name) do result[name] = code end
    return result
end

-- Encode a constant operand as a negative RK reference (registers are >= 0, so a
-- negative operand always names constant index -x). Constant indices start at 1.
function RegBytecode.rk_const(kidx) return -kidx end
function RegBytecode.rk_is_const(x) return x < 0 end
function RegBytecode.rk_index(x) return -x end

-- ---- serialization ----------------------------------------------------------
-- A compact binary encoding of the proto tree, so the program can be ChaCha-
-- encrypted and embedded (no source text, no plaintext bytecode). Integers are
-- little-endian; signed operands are stored biased by 2^31. Numeric constants
-- round-trip through %.17g. No load/loadstring is involved.

local char, byte, format, concat = string.char, string.byte, string.format, table.concat
local floor = math.floor

RegBytecode.MAGIC = "CLRV"
RegBytecode.VERSION = 1

local function u8(n) return char(n % 256) end
local function u16(n) return char(n % 256, floor(n / 256) % 256) end
local function u32(n) return char(n % 256, floor(n / 256) % 256, floor(n / 65536) % 256, floor(n / 16777216) % 256) end
local function i32(n) return u32((n + 2147483648) % 4294967296) end
local function str(s) return u32(#s) .. s end

local function w_proto(p, out)
    out[#out + 1] = u8(p.numparams) .. u8(p.is_vararg and 1 or 0) .. u16(p.maxstack or 0)
    out[#out + 1] = u16(#p.upvals)
    for _, d in ipairs(p.upvals) do out[#out + 1] = u8(d.kind == "local" and 0 or 1) .. u16(d.index) end
    out[#out + 1] = u16(#p.constants)
    for _, k in ipairs(p.constants) do
        local t = type(k)
        if t == "number" then out[#out + 1] = u8(0) .. str(format("%.17g", k))
        elseif t == "string" then out[#out + 1] = u8(1) .. str(k)
        elseif t == "boolean" then out[#out + 1] = u8(2) .. u8(k and 1 or 0)
        else out[#out + 1] = u8(3) end
    end
    out[#out + 1] = u32(#p.code)
    for _, inst in ipairs(p.code) do
        out[#out + 1] = u8(inst[1]) .. i32(inst[2]) .. i32(inst[3]) .. i32(inst[4])
    end
    out[#out + 1] = u16(#p.protos)
    for _, child in ipairs(p.protos) do w_proto(child, out) end
end

function RegBytecode.encode(mainproto)
    local out = { RegBytecode.MAGIC, u8(RegBytecode.VERSION) }
    w_proto(mainproto, out)
    return concat(out)
end

function RegBytecode.decode(data)
    local pos = 1
    local function rd(n) local s = data:sub(pos, pos + n - 1); pos = pos + n; return s end
    local function ru8() local b = byte(data, pos); pos = pos + 1; return b end
    local function ru16() local a, b = byte(data, pos, pos + 1); pos = pos + 2; return a + b * 256 end
    local function ru32() local a, b, c, d = byte(data, pos, pos + 3); pos = pos + 4; return a + b * 256 + c * 65536 + d * 16777216 end
    local function ri32() return ru32() - 2147483648 end
    local function rstr() local n = ru32(); return rd(n) end
    if rd(4) ~= RegBytecode.MAGIC then error("reg-bytecode: bad magic") end
    if ru8() ~= RegBytecode.VERSION then error("reg-bytecode: bad version") end
    local function r_proto()
        local p = { code = {}, constants = {}, protos = {}, upvals = {} }
        p.numparams = ru8(); p.is_vararg = ru8() == 1; p.maxstack = ru16()
        for _ = 1, ru16() do local k = ru8(); p.upvals[#p.upvals + 1] = { kind = k == 0 and "local" or "upval", index = ru16() } end
        for _ = 1, ru16() do
            local t = ru8()
            if t == 0 then p.constants[#p.constants + 1] = tonumber(rstr())
            elseif t == 1 then p.constants[#p.constants + 1] = rstr()
            elseif t == 2 then p.constants[#p.constants + 1] = ru8() == 1
            else p.constants[#p.constants + 1] = nil end
        end
        local ncode = ru32()
        for i = 1, ncode do p.code[i] = { ru8(), ri32(), ri32(), ri32() } end
        for _ = 1, ru16() do p.protos[#p.protos + 1] = r_proto() end
        return p
    end
    return r_proto()
end

return RegBytecode
