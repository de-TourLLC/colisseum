local Lexer = {}

local function long_open(source, index)
    if source:sub(index, index) ~= "[" then return nil end
    local close = source:find("[", index + 1, true)
    if not close then return nil end
    local equals = source:sub(index + 1, close - 1)
    if equals:match("^=*$") and source:sub(close, close) == "[" then
        return "]" .. equals .. "]", close + 1
    end
end

local function read_long(source, index)
    local ending, content = long_open(source, index)
    if not ending then return nil end
    local finish = source:find(ending, content + 1, true)
    if not finish then return #source + 1, source:sub(content) end
    return finish + #ending, source:sub(content, finish - 1)
end

local function add(result, kind, value, start, finish, protected)
    result[#result + 1] = {
        kind = kind, value = value, start = start, finish = finish,
        protected = protected == true
    }
end

function Lexer.scan(source)
    if type(source) ~= "string" then error("lexer: source must be a string") end
    local result = {}
    local index = 1
    while index <= #source do
        local start = index
        local char = source:sub(index, index)
        if char:match("%s") then
            index = index + 1
        elseif char == "-" and source:sub(index, index + 1) == "--" then
            local finish, value = read_long(source, index + 2)
            if finish then
                add(result, "comment", source:sub(index, finish - 1), index, finish - 1, true)
                index = finish
            else
                finish = source:find("\n", index + 2, true) or (#source + 1)
                add(result, "comment", source:sub(index, finish - 1), index, finish - 1, true)
                index = finish
            end
        elseif char == "[" then
            local finish, value = read_long(source, index)
            if finish then
                add(result, "string", source:sub(index, finish - 1), index, finish - 1, true)
                index = finish
            else
                add(result, "symbol", char, index, index)
                index = index + 1
            end
        elseif char == "\"" or char == "'" then
            local quote = char
            index = index + 1
            while index <= #source do
                local current = source:sub(index, index)
                if current == "\\" then index = index + 2
                elseif current == quote then index = index + 1; break
                else index = index + 1 end
            end
            add(result, "string", source:sub(start, index - 1), start, index - 1, true)
        elseif char:match("[%a_]") then
            index = index + 1
            while source:sub(index, index):match("[%w_]") do index = index + 1 end
            add(result, "identifier", source:sub(start, index - 1), start, index - 1)
        elseif char:match("%d") or (char == "." and source:sub(index + 1, index + 1):match("%d")) then
            local value = source:sub(index):match("^0[xX]%x+") or
                source:sub(index):match("^0[bB][01]+") or
                source:sub(index):match("^%d+%.?%d*[eE][%+%-]?%d+") or
                source:sub(index):match("^%d+%.?%d*") or
                source:sub(index):match("^%.[%d]+")
            index = index + #value
            add(result, "number", source:sub(start, index - 1), start, index - 1)
        else
            local three = source:sub(index, index + 2)
            local two = source:sub(index, index + 1)
            local symbol
            -- Multi-character operators must lex as ONE token, otherwise a later
            -- step could insert whitespace/comments between the halves. In Luau,
            -- splitting `->` (function types) or `+=`/`..=` (compound assignment)
            -- produces invalid syntax.
            if three == "..." or three == "//=" or three == "..=" then
                symbol = three; index = index + 3
            elseif two == ".." or two == "==" or two == "~=" or two == "<=" or two == ">=" or
                two == "::" or two == "->" or two == "+=" or two == "-=" or two == "*=" or
                two == "/=" or two == "%=" or two == "^=" then
                symbol = two; index = index + 2
            else symbol = char; index = index + 1 end
            add(result, "symbol", symbol, start, index - 1)
        end
    end
    return result
end

return Lexer
