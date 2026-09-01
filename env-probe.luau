print(type(string), type(string.reverse), type(table), type(table.insert), type(getfenv), type(_G))
local e = getfenv(0)
print(type(e), type(e.string), type(e.string and e.string.reverse))
