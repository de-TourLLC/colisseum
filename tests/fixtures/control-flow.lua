local total = 0
for index = 1, 5 do
    if index % 2 == 1 then
        total = total + index
    end
end
local count = 0
repeat
    count = count + 1
until count == 3
return total, count
