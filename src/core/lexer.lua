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
    -- Optional CLI progress tick; nil in library/test use, called every few thousand iterations.
    local tick = _G.__colisseum_tick
    local since_tick = 0
    while index <= #source do
        if tick then
            since_tick = since_tick + 1
            if since_tick >= 4096 then since_tick = 0; tick() end
        end
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
        elseif char == "`" then
            --[[ Luau interpolated string: grab it whole, tracking {} hole depth and
                 skipping quoted strings inside holes so a } or backtick there doesn't
                 end it early. the parser desugars it. ]]
            local j = index + 1
            local depth = 0
            while j <= #source do
                local ch = source:sub(j, j)
                if ch == "\\" then j = j + 2
                elseif depth == 0 and ch == "`" then j = j + 1; break
                elseif ch == "{" then depth = depth + 1; j = j + 1
                elseif ch == "}" and depth > 0 then depth = depth - 1; j = j + 1
                elseif (ch == "\"" or ch == "'") and depth > 0 then
                    local q = ch; j = j + 1
                    while j <= #source do
                        local c2 = source:sub(j, j)
                        if c2 == "\\" then j = j + 2 elseif c2 == q then j = j + 1; break else j = j + 1 end
                    end
                else j = j + 1 end
            end
            add(result, "interp", source:sub(index, j - 1), index, j - 1, true)
            index = j
        elseif char:match("[%a_]") then
            index = index + 1
            while source:sub(index, index):match("[%w_]") do index = index + 1 end
            add(result, "identifier", source:sub(start, index - 1), start, index - 1)
        elseif char:match("%d") or (char == "." and source:sub(index + 1, index + 1):match("%d")) then
            --[[ `_` digit separators (1_000_000): accept them, then store the value
                 with underscores stripped so tonumber works and the literal stays valid. ]]
            local value = source:sub(index):match("^0[xX][%x_]+") or
                source:sub(index):match("^0[bB][01_]+") or
                source:sub(index):match("^%d[%d_]*%.?[%d_]*[eE][%+%-]?[%d_]+") or
                source:sub(index):match("^%d[%d_]*%.?[%d_]*") or
                source:sub(index):match("^%.[%d_]+")
            index = index + #value
            add(result, "number", (source:sub(start, index - 1):gsub("_", "")), start, index - 1)
        else
            local three = source:sub(index, index + 2)
            local two = source:sub(index, index + 1)
            local symbol
            -- Multi-char operators must lex as a single token, or a later step could
            -- insert text between the halves and break syntax like `->` or `+=`.
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
