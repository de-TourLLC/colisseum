-- Bounded interpreter for CLBC.  It executes the AST-shaped, post-order
-- format only; it never turns data back into Lua source.
local Bytecode = require("src.core.bytecode")

local unpack_fn = table.unpack or unpack
-- Hoist the hot library functions into locals: in a tree-walking interpreter these
-- are touched on nearly every node, and a local read is far cheaper than a global
-- table lookup on both Lua/LuaJIT and Luau.
local type, tonumber, select, error, setmetatable = type, tonumber, select, error, setmetatable
local math_floor, math_huge = math.floor, math.huge
local string_char, table_concat = string.char, table.concat
-- Sentinel stored for a declared local whose value is nil, so one table per scope
-- (values) can replace the values+declared pair: a key present but == NIL means
-- "declared, holds nil"; a key absent (nil) means "not declared here".
local NIL = {}
-- Pack return values with an exact count so nil holes in the middle survive
-- (plain { f() } + # truncates at the first nil).
local function pack(...) return { n = select("#", ...), ... } end

local Runtime = {}
-- Generous ceilings so obfuscated programs run to completion. They still bound
-- runaway execution, and callers (e.g. the analysis sandbox) may pass lower ones.
Runtime.LIMITS = { steps = 2000000000, depth = 100000, loop_iterations = 2000000000 }

local names = {}
for name, code in pairs(Bytecode.opcodes()) do names[code] = name end

local function fail(message) error("runtime: " .. message, 3) end
local function integer(value, name, maximum)
    if type(value) ~= "number" or value < 1 or value ~= math.floor(value) or value > maximum then
        fail(name .. " must be an integer in range 1.." .. maximum)
    end
    return value
end
local function get_limits(options)
    options = options or {}
    local result = {}
    for name, default in pairs(Runtime.LIMITS) do
        result[name] = integer(options[name] == nil and default or options[name], name, default)
    end
    return result
end
local function reference(value, instruction, operand)
    if type(value) ~= "table" or type(value.ref) ~= "number" then
        fail("instruction " .. instruction .. "." .. operand .. " requires a reference")
    end
    return value.ref
end
local function truthy(value) return value ~= nil and value ~= false end
local function number(value, context)
    if type(value) ~= "number" then fail(context .. " requires numbers") end
    return value
end
local function finite(value, context)
    if value ~= value or value == math.huge or value == -math.huge then fail(context .. " produced a non-finite number") end
    return value
end

-- CLBC retains source spelling for strings.  Decode the non-executable Lua
-- string syntax here instead of using load/loadstring.
local function decode_string(source, id)
    if source:sub(1, 1) == "[" then
        local close = source:match("^%[(=*)%[")
        if not close then fail("invalid long string at instruction " .. id) end
        local ending = "]" .. close .. "]"
        local start = 3 + #close
        if source:sub(-#ending) ~= ending then fail("unterminated long string at instruction " .. id) end
        return source:sub(start, #source - #ending)
    end
    local quote = source:sub(1, 1)
    if (quote ~= "'" and quote ~= "\"") or source:sub(-1) ~= quote then fail("invalid string at instruction " .. id) end
    local body, out, i = source:sub(2, -2), {}, 1
    while i <= #body do
        local c = body:sub(i, i)
        if c ~= "\\" then out[#out + 1], i = c, i + 1
        else
            i = i + 1
            local e = body:sub(i, i)
            local escapes = { ["a"]="\a", ["b"]="\b", ["f"]="\f", ["n"]="\n", ["r"]="\r", ["t"]="\t", ["v"]="\v", ["\\"]="\\", ["\""]="\"", ["'"]="'" }
            if escapes[e] then out[#out + 1] = escapes[e]; i = i + 1
            elseif e == "\n" then out[#out + 1] = "\n"; i = i + 1
            elseif e:match("%d") then
                local digits = body:sub(i):match("^%d%d?%d?")
                local value = tonumber(digits)
                if value > 255 then fail("invalid string escape at instruction " .. id) end
                out[#out + 1] = string.char(value); i = i + #digits
            else fail("unsupported string escape at instruction " .. id) end
        end
    end
    return table.concat(out)
end

local expected = {
    number=1, string=1, literal=1, identifier=1, group=1, unary=2, binary=3,
    member=3, index=2, assign=2, expression=1
}
local expression_node = { number=true, string=true, literal=true, identifier=true, group=true, table=true,
    unary=true, binary=true, member=true, index=true, call=true, ["function"]=true }
local statement_node = { chunk=true, ["do"]=true, expression=true, assign=true, ["local"]=true,
    ["return"]=true, ["if"]=true, ["while"]=true, ["repeat"]=true, ["for"]=true, ["function"]=true }

local function validate_shape(program, id, instruction)
    local opcode = names[instruction.opcode]
    if not opcode then fail("unknown opcode at instruction " .. id) end
    local count = #instruction.operands
    if expected[opcode] and count ~= expected[opcode] then fail("invalid operand shape at instruction " .. id .. " (" .. opcode .. ")") end
    if opcode == "field" and count ~= 2 then fail("invalid field at instruction " .. id) end
    if opcode == "call" and count < 1 then fail("call requires a callee at instruction " .. id) end
    if opcode == "function" and count < 2 then fail("invalid function at instruction " .. id) end
    if opcode == "while" and count < 2 then fail("invalid while at instruction " .. id) end
    if opcode == "repeat" and count < 2 then fail("invalid repeat at instruction " .. id) end
    if opcode == "for" and count < 3 then fail("invalid for at instruction " .. id) end
    if (opcode == "unary" or opcode == "binary") and type(instruction.operands[1]) ~= "string" then fail("invalid operator at instruction " .. id) end
    if opcode == "member" and type(instruction.operands[2]) ~= "string" then fail("invalid member at instruction " .. id) end
    return opcode
end

function Runtime.validate(program)
    Bytecode.validate(program)
    for id, instruction in ipairs(program.instructions) do validate_shape(program, id, instruction) end
    return true
end

function Runtime.inspect(program)
    Runtime.validate(program)
    local result = { version=program.version, root=program.root, instructions=#program.instructions, opcodes={} }
    for _, instruction in ipairs(program.instructions) do local name=names[instruction.opcode]; result.opcodes[name]=(result.opcodes[name] or 0)+1 end
    return result
end

function Runtime.run(program, options)
    Runtime.validate(program)
    local limit, instructions = get_limits(options), program.instructions
    -- Cache the ceilings the hot loops compare against on every node.
    local step_limit, depth_limit, iteration_limit = limit.steps, limit.depth, limit.loop_iterations
    -- Undefined identifiers resolve against the host globals (the standard
    -- library: print, ipairs, string, table, math, ...). Override via
    -- options.environment. The step/loop/depth limits still bound execution.
    local globals = (options and options.environment) or _G
    local steps, depth, loop_iterations = 0, 0, 0
    local returned, return_values
    -- `broke` signals a `break`: it unwinds the innermost enclosing loop only and
    -- is cleared by that loop once it exits (unlike `returned`, which propagates).
    local broke = false
    local eval, execute, eval_call, eval_multi

    local function tick() steps=steps+1; if steps > limit.steps then fail("step limit exceeded") end end
    local function enter() depth=depth+1; if depth > limit.depth then fail("evaluation depth limit exceeded") end end
    local function leave() depth=depth-1 end
    local function child(id, parent, operand) return reference(instructions[id].operands[operand], id, operand) end
    local function env_new(parent) return { parent=parent, values={} } end
    local function find_varargs(environment)
        while environment do if environment.varargs then return environment.varargs end; environment=environment.parent end
        return { n = 0 }
    end
    local function lookup(environment, name)
        while environment do local val=environment.values[name]; if val~=nil then if val==NIL then return nil end; return val end; environment=environment.parent end
        return nil
    end
    local function assign(environment, name, value)
        if value==nil then value=NIL end
        local current=environment
        while current do if current.values[name]~=nil then current.values[name]=value; return end; current=current.parent end
        environment.values[name]=value
    end
    local function scalar(value, context)
        if type(value) == "string" or type(value) == "number" or type(value) == "boolean" or value == nil then return tostring(value) end
        fail(context .. " only accepts scalar values")
    end
    local function sequence(ids, environment)
        for _, id in ipairs(ids) do execute(id, environment); if returned or broke then break end end
    end

    eval = function(id, environment)
        -- Inlined tick()+enter(): this runs on every evaluated node, so the two
        -- function calls are unrolled and the ceilings read from locals.
        steps=steps+1; if steps>step_limit then fail("step limit exceeded") end
        depth=depth+1; if depth>depth_limit then fail("evaluation depth limit exceeded") end
        local op, v = names[instructions[id].opcode], instructions[id].operands
        local result
        if op == "identifier" then
            local nm=v[1]; local scope=environment
            while scope do local val=scope.values[nm]; if val~=nil then depth=depth-1; if val==NIL then return nil end; return val end; scope=scope.parent end
            depth=depth-1; return globals[nm]
        elseif op == "binary" then
            local left=eval(child(id,environment,2),environment); local operator=v[1]
            if operator=="and" then if truthy(left) then result=eval(child(id,environment,3),environment) else result=left end
            elseif operator=="or" then if truthy(left) then result=left else result=eval(child(id,environment,3),environment) end
            else local right=eval(child(id,environment,3),environment)
                if operator=="+" then result=number(left,"addition")+number(right,"addition") elseif operator=="-" then result=number(left,"subtraction")-number(right,"subtraction") elseif operator=="*" then result=number(left,"multiplication")*number(right,"multiplication") elseif operator=="/" then result=number(left,"division")/number(right,"division") elseif operator=="//" then result=math_floor(number(left,"floor division")/number(right,"floor division")) elseif operator=="%" then result=number(left,"remainder")%number(right,"remainder") elseif operator=="^" then result=number(left,"power")^number(right,"power") elseif operator==".." then result=scalar(left,"concatenation")..scalar(right,"concatenation") elseif operator=="==" then result=left==right elseif operator=="~=" then result=left~=right elseif operator=="<" then result=left<right elseif operator==">" then result=left>right elseif operator=="<=" then result=left<=right elseif operator==">=" then result=left>=right else fail("unsupported binary operator '"..operator.."'") end
            end
            if type(result)=="number" and (result~=result or result==math_huge or result==-math_huge) then fail("arithmetic produced a non-finite number") end
        elseif op=="call" then result=eval_call(id, environment)[1]
        elseif op=="index" or op=="member" then local object=eval(child(id,environment,1),environment); local key=op=="member" and v[2] or eval(child(id,environment,2),environment); if object==nil then fail("attempt to index a nil value") end; result=object[key]
        elseif op == "number" then result=finite(tonumber(v[1]), "number")
        elseif op == "string" then result=decode_string(v[1], id)
        elseif op == "literal" then if v[1]=="nil" then result=nil elseif v[1]=="true" then result=true elseif v[1]=="false" then result=false else fail("invalid literal") end
        elseif op == "group" then result=eval(child(id, environment, 1), environment)
        elseif op == "table" then
            result={}; local index=1; local count=v[1]
            if type(count)~="number" or count<0 or count~=#v-1 then fail("invalid table layout") end
            for n=2,#v do local cid=reference(v[n],id,n); local cop=names[instructions[cid].opcode]
                if cop=="field" then local f=instructions[cid].operands; if type(f[1])~="string" then fail("invalid table field") end; result[f[1]]=eval(reference(f[2],cid,2),environment)
                elseif cop=="keyfield" then local f=instructions[cid].operands; local kk=eval(reference(f[1],cid,1),environment); if kk==nil then fail("table key is nil") end; result[kk]=eval(reference(f[2],cid,2),environment)
                elseif n==#v and (cop=="vararg" or cop=="call") then local multi,mn=eval_multi(cid,environment); for k=1,mn do result[index]=multi[k]; index=index+1 end
                else result[index]=eval(cid,environment); index=index+1 end
            end
        elseif op == "unary" then
            local x=eval(child(id,environment,2),environment); if v[1]=="not" then result=not truthy(x) elseif v[1]=="-" then result=-number(x,"unary minus") elseif v[1]=="#" then if type(x)=="string" or type(x)=="table" then result=#x else fail("length requires a string or table") end else fail("unsupported unary operator '"..v[1].."'") end
        elseif op=="function" then
            local name, is_local, parameter_count = v[1], v[2], v[3]
            if type(name)~="string" or type(is_local)~="boolean" or type(parameter_count)~="number" or parameter_count<0 then fail("invalid function layout") end
            local parameters={}; for n=1,parameter_count do local p=v[3+n]; if type(p)~="string" then fail("invalid parameter") end; parameters[n]=p end
            local body_count=v[4+parameter_count]; if type(body_count)~="number" or body_count<0 or body_count~=#v-(4+parameter_count) then fail("invalid function body layout") end
            local body={}; for n=1,body_count do body[n]=reference(v[4+parameter_count+n],id,4+parameter_count+n) end
            -- A VM closure is a REAL Lua function that runs the body on the VM. This
            -- lets native code (pcall, table.sort, metamethods, callbacks) call it
            -- directly, and unifies calling with native functions.
            local closure_env=environment
            result=function(...)
                local nargs=select("#",...); local args={...}
                local call_env=env_new(closure_env)
                for n=1,#parameters do
                    local pname=parameters[n]
                    if pname=="..." then local rest={n=0}; for k=n,nargs do rest.n=rest.n+1; rest[rest.n]=args[k] end; call_env.varargs=rest; break end
                    local av=args[n]; call_env.values[pname]= av==nil and NIL or av
                end
                local old_return, old_values, old_broke = returned, return_values, broke
                returned=false; return_values=nil; broke=false
                sequence(body, call_env)
                local results=return_values or {}
                returned, return_values, broke = old_return, old_values, old_broke
                return unpack_fn(results, 1, results.n or #results)
            end
        elseif op=="vararg" then result=find_varargs(environment)[1]
        else fail("instruction "..id.." is not an expression") end
        depth=depth-1; return result
    end

    -- Invoke a callee (VM closures are real functions too) with pre-evaluated
    -- args, returning ALL of its values.
    local function invoke(callee, args, argn)
        if type(callee) ~= "function" then fail("attempt to call a " .. type(callee) .. " value") end
        return pack(callee(unpack_fn(args, 1, argn)))
    end

    -- A call returning ALL of its values. The last argument expands its own
    -- multiple values, matching Lua semantics.
    eval_call = function(id, environment)
        tick()
        local v = instructions[id].operands
        local argument_count = v[2]
        if type(argument_count) ~= "number" or argument_count < 0 or #v ~= argument_count + 2 then fail("invalid call layout") end
        local callee_id = reference(v[1], id, 1)
        local args, argn = {}, 0
        local callee
        if names[instructions[callee_id].opcode] == "member" and instructions[callee_id].operands[3] == true then
            -- method call a:m(...): evaluate `a` exactly once, then look up m on it.
            local object = eval(child(callee_id, environment, 1), environment)
            if object == nil then fail("attempt to index a nil value") end
            callee = object[instructions[callee_id].operands[2]]
            argn = 1; args[1] = object
        else
            callee = eval(callee_id, environment)
        end
        for n = 1, argument_count do
            local arg_id = reference(v[n + 2], id, n + 2)
            if n == argument_count then
                local multi, mn = eval_multi(arg_id, environment)
                for k = 1, mn do argn = argn + 1; args[argn] = multi[k] end
            else
                argn = argn + 1; args[argn] = eval(arg_id, environment)
            end
        end
        return invoke(callee, args, argn)
    end

    -- Evaluate an expression to its full value list (calls and `...` expand).
    eval_multi = function(id, environment)
        local op = names[instructions[id].opcode]
        if op == "call" then local r = eval_call(id, environment); return r, r.n or #r end
        if op == "vararg" then local va = find_varargs(environment); return va, va.n or #va end
        return { eval(id, environment) }, 1
    end

    local function set_target(id, environment, value)
        local instruction,op,v=instructions[id],names[instructions[id].opcode],instructions[id].operands
        if op=="identifier" then assign(environment,v[1],value) elseif op=="member" or op=="index" then local object=eval(reference(v[1],id,1),environment); if object==nil then fail("attempt to index a nil value") end; object[op=="member" and v[2] or eval(reference(v[2],id,2),environment)]=value else fail("invalid assignment target") end
    end
    execute = function(id, environment)
        steps=steps+1; if steps>step_limit then fail("step limit exceeded") end
        depth=depth+1; if depth>depth_limit then fail("evaluation depth limit exceeded") end
        local op,v=names[instructions[id].opcode],instructions[id].operands
        if op=="chunk" or op=="do" then local count=v[1]; if type(count)~="number" or count<0 or #v~=count+1 then fail("invalid block layout") end; local r={}; for n=1,count do r[n]=reference(v[n+1],id,n+1) end; sequence(r,env_new(environment))
        elseif op=="expression" then eval(reference(v[1],id,1),environment)
        elseif op=="assign" then set_target(reference(v[1],id,1),environment,eval(reference(v[2],id,2),environment))
        elseif op=="massign" then
            local targets_count=v[1]; local pos=2; local target_ids={}
            for n=1,targets_count do target_ids[n]=reference(v[pos],id,pos); pos=pos+1 end
            local values_count=v[pos]; pos=pos+1
            local vals,vn={},0
            for n=1,values_count do local vid=reference(v[pos],id,pos); pos=pos+1
                if n==values_count then local multi,mn=eval_multi(vid,environment); for k=1,mn do vn=vn+1; vals[vn]=multi[k] end
                else vn=vn+1; vals[vn]=eval(vid,environment) end
            end
            for n=1,targets_count do set_target(target_ids[n],environment,vals[n]) end
        elseif op=="local" then local names_count, values_count=v[1],v[2+v[1]]; if type(names_count)~="number" or type(values_count)~="number" then fail("invalid local layout") end; local values,vn={},0; for n=1,values_count do local vid=reference(v[2+names_count+n],id,2+names_count+n); if n==values_count then local multi,mn=eval_multi(vid,environment); for k=1,mn do vn=vn+1; values[vn]=multi[k] end else vn=vn+1; values[vn]=eval(vid,environment) end end; for n=1,names_count do local lv=values[n]; environment.values[v[1+n]]= lv==nil and NIL or lv end
        elseif op=="return" then local count=v[1]; if type(count)~="number" or #v~=count+1 then fail("invalid return layout") end; return_values={}; local rn=0; for n=1,count do local rid=reference(v[n+1],id,n+1); if n==count then local multi,mn=eval_multi(rid,environment); for k=1,mn do rn=rn+1; return_values[rn]=multi[k] end else rn=rn+1; return_values[rn]=eval(rid,environment) end end; return_values.n=rn; returned=true
        elseif op=="break" then broke=true
        elseif op=="function" then local closure=eval(id,environment); environment.values[v[1]]=closure
        elseif op=="if" then local branches=v[1]; local pos=2; local chosen=false; for b=1,branches do local condition=reference(v[pos],id,pos); local count=v[pos+1]; pos=pos+2; local body={}; for n=1,count do body[n]=reference(v[pos],id,pos); pos=pos+1 end; if not chosen and truthy(eval(condition,environment)) then chosen=true; sequence(body,env_new(environment)) end end; local fallback=v[pos]; pos=pos+1; if type(fallback)~="number" or pos+fallback-1~=#v then fail("invalid if layout") end; if not chosen then local body={}; for n=1,fallback do body[n]=reference(v[pos],id,pos); pos=pos+1 end; sequence(body,env_new(environment)) end
        elseif op=="while" then local count=0; local body_count=v[2]; if type(body_count)~="number" or #v~=body_count+2 then fail("invalid while layout") end; while truthy(eval(reference(v[1],id,1),environment)) do count=count+1; loop_iterations=loop_iterations+1; if count>iteration_limit or loop_iterations>iteration_limit then fail("loop iteration limit exceeded") end; for n=1,body_count do execute(reference(v[n+2],id,n+2),environment); if returned or broke then break end end; if returned or broke then break end end; broke=false
        elseif op=="repeat" then local body_count=v[1]; if type(body_count)~="number" or #v~=body_count+2 then fail("invalid repeat layout") end; local condition=reference(v[body_count+2],id,body_count+2); local count=0; repeat count=count+1; loop_iterations=loop_iterations+1; if count>iteration_limit or loop_iterations>iteration_limit then fail("loop iteration limit exceeded") end; for n=1,body_count do execute(reference(v[n+1],id,n+1),environment); if returned or broke then break end end; until returned or broke or truthy(eval(condition,environment)); broke=false
        elseif op=="for" then
            local current=number(eval(reference(v[2],id,2),environment),"for initial"); local finish=number(eval(reference(v[3],id,3),environment),"for limit")
            local has_step=v[4]; if type(has_step)~="boolean" then fail("invalid for layout") end; local body_start=6; local step=1
            if has_step then step=number(eval(reference(v[5],id,5),environment),"for step"); body_start=7 end
            local body_count=v[body_start-1]; if type(body_count)~="number" or #v~=body_count+body_start-1 then fail("invalid for body layout") end
            if step==0 then fail("for step cannot be zero") end
            local body=env_new(environment); local count=0
            while (step>0 and current<=finish) or (step<0 and current>=finish) do count=count+1; loop_iterations=loop_iterations+1; if count>iteration_limit or loop_iterations>iteration_limit then fail("loop iteration limit exceeded") end; body.values[v[1]]=current; for n=body_start,#v do execute(reference(v[n],id,n),body); if returned or broke then break end end; current=current+step; if returned or broke then break end end; broke=false
        elseif op=="forin" then
            -- generic for: for names in explist do body end (Lua iterator protocol)
            local names_count=v[1]; if type(names_count)~="number" then fail("invalid forin layout") end
            local pos=2; local var_names={}
            for n=1,names_count do var_names[n]=v[pos]; pos=pos+1 end
            local exprs_count=v[pos]; pos=pos+1; if type(exprs_count)~="number" then fail("invalid forin layout") end
            local iter_vals, ivn = {}, 0
            for n=1,exprs_count do local eid=reference(v[pos],id,pos); pos=pos+1
                if n==exprs_count then local multi,mn=eval_multi(eid,environment); for k=1,mn do ivn=ivn+1; iter_vals[ivn]=multi[k] end
                else ivn=ivn+1; iter_vals[ivn]=eval(eid,environment) end
            end
            local iter_fn, state, control = iter_vals[1], iter_vals[2], iter_vals[3]
            local body_count=v[pos]; pos=pos+1; if type(body_count)~="number" or #v~=pos+body_count-1 then fail("invalid forin body layout") end
            local body={}; for n=1,body_count do body[n]=reference(v[pos],id,pos); pos=pos+1 end
            local count=0
            while true do
                local rets=invoke(iter_fn, { state, control }, 2)
                control=rets[1]; if control==nil then break end
                count=count+1; loop_iterations=loop_iterations+1
                if count>iteration_limit or loop_iterations>iteration_limit then fail("loop iteration limit exceeded") end
                local body_env=env_new(environment)
                for n=1,names_count do local rv=rets[n]; body_env.values[var_names[n]]= rv==nil and NIL or rv end
                for n=1,body_count do execute(body[n],body_env); if returned or broke then break end end
                if returned or broke then break end
            end
            broke=false
        else fail("instruction "..id.." is not a statement") end
        depth=depth-1
    end
    if names[instructions[program.root].opcode]~="chunk" then fail("root must be a chunk") end
    execute(program.root,env_new(nil))
    return return_values or {}, { steps=steps, loop_iterations=loop_iterations }
end

return Runtime
