-- Safe, deliberately small bytecode container for the parser AST.
-- This module never evaluates decoded data.
local Bytecode = {}

Bytecode.MAGIC = "CLBC"
-- Version 2 makes every variable-length instruction self describing.  The
-- opcode table and the public API remain unchanged.
Bytecode.VERSION = 2
Bytecode.LIMITS = {
    bytes = 16 * 1024 * 1024,
    instructions = 1000000,
    operands = 65535,
    strings = 1024 * 1024,
    depth = 256
}

local by_name, by_code = {}, {}
local kinds = {
    "chunk", "number", "string", "literal", "identifier", "group", "table", "field",
    "member", "index", "call", "unary", "binary", "function", "for", "repeat", "if",
    "while", "do", "local", "return", "assign", "expression", "forin", "vararg", "keyfield", "massign",
    "break"
}

local function fail(message) error("bytecode: " .. message, 2) end
local function integer(value, name, maximum)
    if type(value) ~= "number" or value < 0 or value ~= math.floor(value) or value > maximum then
        fail(name .. " must be an integer in range 0.." .. maximum)
    end
    return value
end

for code, name in ipairs(kinds) do
    by_name[name] = code
    by_code[code] = name
end

function Bytecode.register(name, code)
    if type(name) ~= "string" or not name:match("^[%a_][%w_]*$") then fail("invalid opcode name") end
    integer(code, "opcode", 65535)
    if by_name[name] or by_code[code] then fail("opcode already registered") end
    by_name[name], by_code[code] = code, name
    return code
end

function Bytecode.opcode(name)
    if type(name) ~= "string" or not by_name[name] then fail("unknown opcode '" .. tostring(name) .. "'") end
    return by_name[name]
end

local function u8(n) return string.char(n) end
local function u16(n) return string.char(math.floor(n / 256), n % 256) end
local function u32(n)
    return string.char(math.floor(n / 16777216) % 256, math.floor(n / 65536) % 256,
        math.floor(n / 256) % 256, n % 256)
end

local function read_u(data, pos, size)
    if pos + size - 1 > #data then fail("truncated input") end
    local n = 0
    for i = pos, pos + size - 1 do n = n * 256 + data:byte(i) end
    return n, pos + size
end

local function scalar(value, path)
    local kind = type(value)
    if kind == "nil" then return u8(0) end
    if kind == "boolean" then return u8(value and 2 or 1) end
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then fail(path .. " contains non-finite number") end
        local text = tostring(value)
        if #text > 65535 then fail(path .. " number is too long") end
        return u8(3) .. u16(#text) .. text
    end
    if kind == "string" then
        if #value > Bytecode.LIMITS.strings then fail(path .. " string is too long") end
        return u8(4) .. u32(#value) .. value
    end
    if kind == "table" and value.ref then
        integer(value.ref, path .. ".ref", Bytecode.LIMITS.instructions)
        return u8(5) .. u32(value.ref)
    end
    fail(path .. " contains unsupported value")
end

local function decode_scalar(data, pos, limits, path)
    local tag; tag, pos = read_u(data, pos, 1)
    if tag == 0 then return nil, pos end
    if tag == 1 then return false, pos end
    if tag == 2 then return true, pos end
    if tag == 3 then
        local length; length, pos = read_u(data, pos, 2)
        if length == 0 or length > limits.strings or pos + length - 1 > #data then fail(path .. " invalid number") end
        local text = data:sub(pos, pos + length - 1)
        local value = tonumber(text)
        if not value or value ~= value or value == math.huge or value == -math.huge or tostring(value) ~= tostring(tonumber(text)) then fail(path .. " invalid number") end
        return value, pos + length
    end
    if tag == 4 then
        local length; length, pos = read_u(data, pos, 4)
        if length > limits.strings or pos + length - 1 > #data then fail(path .. " invalid string") end
        return data:sub(pos, pos + length - 1), pos + length
    end
    if tag == 5 then
        local ref; ref, pos = read_u(data, pos, 4)
        if ref == 0 or ref > limits.instructions then fail(path .. " invalid reference") end
        return { ref = ref }, pos
    end
    fail(path .. " has invalid value tag " .. tag)
end

local function ref(id) return { ref = id } end
local function Compiler()
    local out = { version = Bytecode.VERSION, instructions = {} }
    local function emit(kind, values)
        local code = by_name[kind]
        if not code then fail("cannot emit unknown AST kind '" .. tostring(kind) .. "'") end
        if #out.instructions >= Bytecode.LIMITS.instructions then fail("instruction limit exceeded") end
        out.instructions[#out.instructions + 1] = { opcode = code, operands = values or {} }
        return #out.instructions
    end
    local visit
    visit = function(node, depth)
        if type(node) ~= "table" or type(node.kind) ~= "string" then fail("invalid AST node") end
        if depth > Bytecode.LIMITS.depth then fail("AST depth limit exceeded") end
        local k = node.kind
        local v = {}
        local function child(x) v[#v + 1] = ref(visit(x, depth + 1)) end
        local function text(x, name) if type(x) ~= "string" then fail(k .. ": " .. name .. " must be a string") end; v[#v + 1] = x end
        local function list(items, name, callback)
            if type(items) ~= "table" then fail(k .. ": " .. name .. " must be a table") end
            for index = 1, #items do
                if items[index] == nil then fail(k .. ": " .. name .. " is not a dense list") end
                callback(items[index], index)
            end
        end
        local function count(n, name)
            if n > Bytecode.LIMITS.operands then fail(k .. ": " .. name .. " is too long") end
            v[#v + 1] = n
        end
        if k == "chunk" then
            count(#node.body, "body")
            list(node.body, "body", function(x) child(x) end)
        elseif k == "number" or k == "string" or k == "literal" or k == "identifier" then v[1] = node.value
        elseif k == "group" or k == "unary" then if k == "unary" then text(node.operator, "operator") end; child(node.value)
        elseif k == "table" then
            count(#node.values, "values")
            list(node.values, "values", function(x) child(x) end)
        elseif k == "field" then text(node.key, "key"); child(node.value)
        elseif k == "keyfield" then child(node.key); child(node.value)
        elseif k == "member" then child(node.object); text(node.name, "name"); v[#v + 1] = node.method == true
        elseif k == "index" then child(node.object); child(node.key)
        elseif k == "call" then
            child(node.callee); count(#node.arguments, "arguments")
            list(node.arguments, "arguments", function(x) child(x) end)
        elseif k == "binary" then text(node.operator, "operator"); child(node.left); child(node.right)
        elseif k == "function" then
            text(node.name, "name"); v[#v + 1] = node.local_function == true
            count(#node.parameters, "parameters")
            list(node.parameters, "parameters", function(x) text(x, "parameter") end)
            count(#node.body, "body")
            list(node.body, "body", function(x) child(x) end)
        elseif k == "for" then
            text(node.name, "name"); child(node.initial); child(node.limit)
            v[#v + 1] = node.step ~= nil
            if node.step then child(node.step) end
            count(#node.body, "body")
            list(node.body, "body", function(x) child(x) end)
        elseif k == "forin" then
            count(#node.names, "names")
            list(node.names, "names", function(x) text(x, "name") end)
            count(#node.exprs, "exprs")
            list(node.exprs, "exprs", function(x) child(x) end)
            count(#node.body, "body")
            list(node.body, "body", function(x) child(x) end)
        elseif k == "vararg" then
            -- no operands; the "..." marker is the opcode itself
        elseif k == "break" then
            -- no operands; the opcode itself is the break
        elseif k == "repeat" then
            count(#node.body, "body")
            list(node.body, "body", function(x) child(x) end)
            child(node.condition)
        elseif k == "if" then
            count(#node.branches, "branches")
            list(node.branches, "branches", function(b)
                if type(b) ~= "table" then fail(k .. ": branch must be a table") end
                child(b.condition); count(#b.body, "branch body")
                list(b.body, "branch body", function(x) child(x) end)
            end)
            count(node.fallback and #node.fallback or 0, "fallback")
            if node.fallback then list(node.fallback, "fallback", function(x) child(x) end) end
        elseif k == "while" then
            child(node.condition); count(#node.body, "body")
            list(node.body, "body", function(x) child(x) end)
        elseif k == "do" then
            count(#node.body, "body")
            list(node.body, "body", function(x) child(x) end)
        elseif k == "local" then
            count(#node.names, "names"); list(node.names, "names", function(x) text(x, "name") end)
            count(#node.values, "values"); list(node.values, "values", function(x) child(x) end)
        elseif k == "return" then
            count(#node.values, "values"); list(node.values, "values", function(x) child(x) end)
        elseif k == "assign" then child(node.target); child(node.value)
        elseif k == "massign" then
            count(#node.targets, "targets")
            list(node.targets, "targets", function(x) child(x) end)
            count(#node.values, "values")
            list(node.values, "values", function(x) child(x) end)
        elseif k == "expression" then child(node.value)
        else fail("unsupported AST kind '" .. k .. "'") end
        return emit(k, v)
    end
    return out, visit
end

function Bytecode.compile(ast)
    if type(ast) ~= "table" or ast.kind ~= "chunk" then fail("expected chunk AST") end
    local program, visit = Compiler()
    visit(ast, 0)
    program.root = #program.instructions
    return program
end

-- Variable layouts (all counts are scalar integer operands):
-- chunk/table/do = count, refs; call = callee, count, refs;
-- function = name, local flag, parameter count, parameter names, body count, refs;
-- for = name, initial, limit, step flag, optional step, body count, refs;
-- repeat = body count, refs, condition; while = condition, body count, refs;
-- if = branch count, (condition, body count, refs)*, fallback count, refs;
-- local = name count, names, value count, refs; return = value count, refs.
local function layout(opcode, operands, id)
    local position = 1
    local function error_at(message) fail("invalid " .. opcode .. " layout at instruction " .. id .. ": " .. message) end
    local function value(message)
        local result = operands[position]
        if result == nil then error_at(message .. " is missing") end
        position = position + 1
        return result
    end
    local function count(message)
        local result = value(message)
        if type(result) ~= "number" or result < 0 or result ~= math.floor(result) or result > Bytecode.LIMITS.operands then
            error_at(message .. " must be a count")
        end
        return result
    end
    local function text(message)
        local result = value(message)
        if type(result) ~= "string" then error_at(message .. " must be a string") end
        return result
    end
    local function flag(message)
        local result = value(message)
        if type(result) ~= "boolean" then error_at(message .. " must be a boolean") end
        return result
    end
    local function reference(message)
        local result = value(message)
        if type(result) ~= "table" or type(result.ref) ~= "number" then error_at(message .. " must be a reference") end
        return result
    end
    local function references(amount, message)
        for n = 1, amount do reference(message .. "[" .. n .. "]") end
    end
    local function finish()
        if position ~= #operands + 1 then error_at("unexpected operand at " .. position) end
    end

    if opcode == "chunk" or opcode == "table" or opcode == "do" then
        local amount = count("items")
        references(amount, "item")
    elseif opcode == "call" then
        reference("callee"); references(count("arguments"), "argument")
    elseif opcode == "function" then
        text("name"); flag("local_function")
        local parameters = count("parameters")
        for n = 1, parameters do text("parameter[" .. n .. "]") end
        references(count("body"), "body")
    elseif opcode == "for" then
        text("name"); reference("initial"); reference("limit")
        if flag("has_step") then reference("step") end
        references(count("body"), "body")
    elseif opcode == "repeat" then
        references(count("body"), "body"); reference("condition")
    elseif opcode == "while" then
        reference("condition"); references(count("body"), "body")
    elseif opcode == "if" then
        local branches = count("branches")
        for n = 1, branches do
            reference("branch[" .. n .. "].condition")
            references(count("branch[" .. n .. "].body"), "branch[" .. n .. "].body")
        end
        references(count("fallback"), "fallback")
    elseif opcode == "local" then
        local names = count("names")
        for n = 1, names do text("name[" .. n .. "]") end
        references(count("values"), "value")
    elseif opcode == "return" then
        references(count("values"), "value")
    elseif opcode == "number" or opcode == "string" or opcode == "literal" or opcode == "identifier" then
        value("value")
    elseif opcode == "group" or opcode == "expression" then
        reference("value")
    elseif opcode == "unary" then
        text("operator"); reference("value")
    elseif opcode == "binary" then
        text("operator"); reference("left"); reference("right")
    elseif opcode == "field" then
        text("key"); reference("value")
    elseif opcode == "keyfield" then
        reference("key"); reference("value")
    elseif opcode == "member" then
        reference("object"); text("name"); flag("method")
    elseif opcode == "index" then
        reference("object"); reference("key")
    elseif opcode == "assign" then
        reference("target"); reference("value")
    elseif opcode == "massign" then
        references(count("targets"), "target")
        references(count("values"), "value")
    elseif opcode == "forin" then
        local nnames = count("names")
        for n = 1, nnames do text("name[" .. n .. "]") end
        references(count("exprs"), "expr")
        references(count("body"), "body")
    elseif opcode == "vararg" then
        -- no operands
    elseif opcode == "break" then
        -- no operands
    end
    finish()
end

function Bytecode.validate(program)
    if type(program) ~= "table" or type(program.instructions) ~= "table" then fail("invalid program") end
    if #program.instructions == 0 or #program.instructions > Bytecode.LIMITS.instructions then fail("instruction limit exceeded") end
    integer(program.root, "root", #program.instructions)
    if program.root == 0 then fail("root is required") end
    for i, instruction in ipairs(program.instructions) do
        if type(instruction) ~= "table" or not by_code[instruction.opcode] then fail("invalid opcode at instruction " .. i) end
        if type(instruction.operands) ~= "table" or #instruction.operands > Bytecode.LIMITS.operands then fail("invalid operands at instruction " .. i) end
        for j, value in ipairs(instruction.operands) do
            if type(value) == "table" and value.ref and
                (value.ref >= i or value.ref < 1 or value.ref > #program.instructions) then
                fail("forward or invalid reference at " .. i .. "." .. j)
            end
            scalar(value, "instruction " .. i .. "." .. j)
        end
        layout(by_code[instruction.opcode], instruction.operands, i)
    end
    return true
end

function Bytecode.encode(program, skip_validate)
    if not skip_validate then Bytecode.validate(program) end
    local parts = { Bytecode.MAGIC, u8(Bytecode.VERSION), u8(0), u32(#program.instructions), u32(program.root) }
    for i, instruction in ipairs(program.instructions) do
        parts[#parts + 1] = u16(instruction.opcode) .. u16(#instruction.operands)
        for j, value in ipairs(instruction.operands) do parts[#parts + 1] = scalar(value, "instruction " .. i .. "." .. j) end
    end
    local result = table.concat(parts)
    if #result > Bytecode.LIMITS.bytes then fail("encoded bytecode exceeds size limit") end
    return result
end

function Bytecode.decode(data, limits)
    if type(data) ~= "string" then fail("encoded bytecode must be a string") end
    local supplied = limits or {}
    limits = {}
    for name, value in pairs(Bytecode.LIMITS) do limits[name] = supplied[name] ~= nil and supplied[name] or value end
    if #data > (limits.bytes or Bytecode.LIMITS.bytes) then fail("input exceeds size limit") end
    if data:sub(1, 4) ~= Bytecode.MAGIC then fail("bad magic") end
    local pos = 5; local version; version, pos = read_u(data, pos, 1)
    if version ~= Bytecode.VERSION then fail("unsupported version " .. version) end
    local flags; flags, pos = read_u(data, pos, 1); if flags ~= 0 then fail("unsupported flags") end
    local count; count, pos = read_u(data, pos, 4); local root; root, pos = read_u(data, pos, 4)
    if count == 0 or count > (limits.instructions or Bytecode.LIMITS.instructions) or root == 0 or root > count then fail("invalid instruction count or root") end
    local program = { version = version, root = root, instructions = {} }
    for i = 1, count do
        local code, operands; code, pos = read_u(data, pos, 2); operands, pos = read_u(data, pos, 2)
        if not by_code[code] then fail("unknown opcode " .. code .. " at instruction " .. i) end
        if operands > (limits.operands or Bytecode.LIMITS.operands) then fail("operand limit exceeded at instruction " .. i) end
        local instruction = { opcode = code, operands = {} }
        for j = 1, operands do instruction.operands[j], pos = decode_scalar(data, pos, limits, "instruction " .. i .. "." .. j) end
        program.instructions[i] = instruction
    end
    if pos ~= #data + 1 then fail("trailing bytes") end
    Bytecode.validate(program)
    return program
end

function Bytecode.opcodes()
    local result = {}; for code, name in pairs(by_code) do result[name] = code end; return result
end

return Bytecode
